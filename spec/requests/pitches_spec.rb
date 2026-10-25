require "rails_helper"

RSpec.describe "Pitches" do
  include ActiveJob::TestHelper

  let(:user) { create(:user, judge: true) }
  let(:show) { create(:show, user: user, title: "The Founder's Ledger", downloads_per_episode: 1500) }
  let(:report) { create(:report, show: show, kind: "agent", status: "done") }
  let(:brand_match) do
    create(:sponsor_match, report: report, name: "Fieldnote Coffee", website: "https://fieldnote.example.com/shop",
                           evidence: { "shared_tags" => [ "Specialty Coffee", "Remote Work" ], "proven" => { "items" => [], "count" => 0 } })
  end
  let(:turbo) { { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" } }
  let(:paused) { Pitch::PAUSED_MESSAGE }

  def page = Nokogiri::HTML5.fragment(response.body)
  def dom_id(*) = ActionView::RecordIdentifier.dom_id(*)

  # The content of the turbo-stream with this action and target.
  def stream(action, target)
    node = page.at_css("turbo-stream[action='#{action}'][target='#{target}']")
    node && Nokogiri::HTML5.fragment(node.at_css("template").inner_html)
  end

  def write_pitch(**params)
    perform_enqueued_jobs { post sponsor_match_pitch_path(brand_match), params: params, headers: turbo }
  end

  # The production 404 page: the test env's detailed error page quotes this spec's source. A request that raises
  # never writes the session cookie (ShowExceptions sits outside the session middleware), so each signs in afresh.
  def with_production_errors
    config = Rails.application.env_config
    detailed = config["action_dispatch.show_detailed_exceptions"]
    config["action_dispatch.show_detailed_exceptions"] = false
    yield
  ensure
    config["action_dispatch.show_detailed_exceptions"] = detailed
  end

  before { allow(Llm).to receive(:mode).and_return(:fake) }

  it "requires sign in" do
    post sponsor_match_pitch_path(brand_match), headers: turbo
    expect(response).to have_http_status(:unauthorized).or redirect_to("/users/sign_in")
    expect(Pitch.count).to eq(0)
  end

  context "when signed in" do
    before { sign_in user }

    describe "POST from the match card" do
      it "queues one pitch and opens the dialog on a skeleton subscribed to the pitch's stream" do
        expect { post sponsor_match_pitch_path(brand_match), headers: turbo }
          .to change(Pitch, :count).by(1).and have_enqueued_job(GeneratePitchJob)

        pitch = Pitch.last
        expect(pitch).to have_attributes(sponsor_match_id: brand_match.id, status: "queued")
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        dialog = stream("update", "pitch_dialog")
        expect(dialog.at_css("[data-controller='dialog'][data-dialog-open-value='true'] dialog")).to be_present
        expect(dialog.at_css("dialog h2").text.squish).to eq("Pitch for Fieldnote Coffee")
        source = dialog.at_css("turbo-cable-stream-source")
        expect(Turbo::StreamsChannel.verified_stream_name(source["signed-stream-name"])).to eq(pitch.to_gid_param)
        expect(dialog.at_css("##{dom_id(pitch)} .skeleton[role='status']")).to be_present
      end

      it "turns the card's button into Open pitch" do
        post sponsor_match_pitch_path(brand_match), headers: turbo

        button = stream("replace", dom_id(brand_match, :pitch_button))
        link = button.at_css("a[href='#{sponsor_match_pitch_path(brand_match)}']")
        expect(link.text.squish).to eq("Open pitch")
        expect(link["data-turbo-stream"]).to eq("true")
      end

      it "streams in the finished pack: email, angles, offer, follow-up and who to contact" do
        write_pitch
        pitch = Pitch.last
        expect(pitch).to be_done

        get sponsor_match_pitch_path(brand_match), headers: turbo
        pack = stream("update", "pitch_dialog").at_css("##{dom_id(pitch)}")

        expect(pack.at_css("[data-pitch-subject]").text.squish).to eq(pitch.subject)
        expect(pack.at_css("[data-pitch-body]").text.strip).to eq(pitch.body)
        expect(pack.text).to include("#{pitch.word_count} words")
        expect(pack.css("ol[data-pitch-angles] li").map { |li| li.text.squish }).to eq(pitch.angles)
        expect(pack.at_css("[data-pitch-offer]").text.squish).to eq(pitch.offer)
        expect(pack.at_css("[data-pitch-follow-up]").text.strip).to eq(pitch.follow_up)
        contact = pack.at_css("[data-pitch-contact]")
        expect(contact.text).to include(pitch.contact_role)
        site = contact.at_css("a[href='https://fieldnote.example.com/shop']")
        expect(site["target"]).to eq("_blank")
        expect(site["rel"]).to include("noopener")
      end

      it "offers Copy with visible, announced feedback and Gmail compose in a new tab" do
        write_pitch
        pitch = Pitch.last
        get sponsor_match_pitch_path(brand_match), headers: turbo
        pack = stream("update", "pitch_dialog")

        subject = pack.at_css("[data-controller='clipboard']:has([data-pitch-subject])")
        expect(subject.at_css("[data-clipboard-target='source'][data-pitch-subject]").text.squish).to eq(pitch.subject)
        subject_label = subject.at_css("button[data-action='clipboard#copy'] [data-clipboard-target='label']")
        expect(subject_label.text.squish).to eq("Copy subject")
        expect(subject_label["aria-live"]).to eq("polite")

        copy = pack.at_css("[data-controller='clipboard']:has([data-pitch-body])")
        expect(copy.at_css("[data-clipboard-target='source'][data-pitch-body]")).to be_present
        label = copy.at_css("button[data-action='clipboard#copy'] [data-clipboard-target='label']")
        expect(label.text.squish).to eq("Copy email")
        expect(label["aria-live"]).to eq("polite")

        gmail = pack.at_xpath(".//a[contains(., 'Open in Gmail')]")
        expect(gmail["href"]).to eq(
          "https://mail.google.com/mail/?view=cm&fs=1&su=#{ERB::Util.url_encode(pitch.subject)}&body=#{ERB::Util.url_encode(pitch.body)}"
        )
        expect(gmail["href"]).to include("%20").and include("%0A")
        expect(gmail["target"]).to eq("_blank")
        expect(gmail["rel"]).to include("noopener")
      end

      it "shows the written pitch again instead of writing another" do
        write_pitch
        expect { write_pitch }.not_to change(Pitch, :count)
        expect(stream("update", "pitch_dialog").at_css("##{dom_id(Pitch.last)}")).to be_present
      end

      it "creates a single pitch when two POSTs on the same match race past the check (R53)" do
        post sponsor_match_pitch_path(brand_match), headers: turbo
        first = Pitch.last
        # The second request didn't see the first's row, so it tries to insert one: the unique index stops it.
        allow_any_instance_of(SponsorMatch).to receive(:latest_pitch).and_return(nil)

        expect { post sponsor_match_pitch_path(brand_match), headers: turbo }.not_to change(Pitch, :count)
        expect(response).to have_http_status(:ok)
        expect(stream("update", "pitch_dialog").at_css("##{dom_id(first)}")).to be_present
      end

      it "fails a pitch stuck in the queue and writes a fresh one" do
        stuck = Pitch.create!(sponsor_match: brand_match, created_at: (Pitch::STALE_AFTER + 1.minute).ago)
        expect { post sponsor_match_pitch_path(brand_match), headers: turbo }.to change(Pitch, :count).by(1)
        expect(stuck.reload).to be_failed
        expect(Pitch.last).to be_queued
      end

      it "never starts a second pitch while one is being written, even on Regenerate" do
        post sponsor_match_pitch_path(brand_match), headers: turbo
        expect { post sponsor_match_pitch_path(brand_match), params: { regenerate: 1 }, headers: turbo }
          .not_to change(Pitch, :count)
      end
    end

    describe "Regenerate" do
      it "writes a new pitch and swaps it into the open dialog; the dialog then shows the newest" do
        write_pitch
        first = Pitch.last

        expect { write_pitch(regenerate: 1) }.to change(Pitch, :count).by(1)
        newest = Pitch.last
        expect(stream("update", "pitch_dialog")).to be_nil
        pack = stream("replace", dom_id(brand_match, :pitch_pack))
        expect(pack.at_css("##{dom_id(newest)}")).to be_present
        expect(pack.at_css("##{dom_id(first)}")).to be_nil

        get sponsor_match_pitch_path(brand_match), headers: turbo
        expect(stream("update", "pitch_dialog").at_css("##{dom_id(newest)}")).to be_present
      end

      it "is a button in the pack that posts regenerate" do
        write_pitch
        get sponsor_match_pitch_path(brand_match), headers: turbo
        form = stream("update", "pitch_dialog").at_xpath(".//form[.//button[contains(., 'Regenerate')]]")
        expect(form["action"]).to eq(sponsor_match_pitch_path(brand_match))
        expect(form.at_css("input[name='regenerate']")["value"]).to eq("1")
      end
    end

    describe "Mark as pitched" do
      def mark_pitched_button
        get sponsor_match_pitch_path(brand_match), headers: turbo
        stream("update", "pitch_dialog").at_xpath(".//form[.//button[contains(., 'Mark as pitched')]]")
      end

      before { write_pitch }

      it "PATCHes the match's existing pipeline update with status pitched" do
        form = mark_pitched_button
        expect(form["action"]).to eq(sponsor_match_path(brand_match))
        expect(form.at_css("input[name='_method']")["value"]).to eq("patch")
        expect(form.at_css("input[name='sponsor_match[status]']")["value"]).to eq("pitched")

        patch sponsor_match_path(brand_match), params: { sponsor_match: { status: "pitched" } }, headers: turbo
        expect(brand_match.reload.status).to eq("pitched")
        expect(stream("replace", dom_id(brand_match, :mark_pitched)).text.squish).to include("Marked as pitched")
      end

      it "is replaced by the link to the copy that counts on a superseded card (R48)" do
        newer_report = create(:report, show: show, kind: "agent", status: "done")
        newer = create(:sponsor_match, report: newer_report, brand_entity_id: brand_match.brand_entity_id, name: "Fieldnote Coffee")

        expect(mark_pitched_button).to be_nil
        link = stream("update", "pitch_dialog")
               .at_css("a[href='#{show_report_path(show, newer_report, anchor: dom_id(newer))}']")
        expect(link.text.squish).to eq("Tracked on your latest report →")
        expect(stream("update", "pitch_dialog").at_xpath(".//a[contains(., 'Open in Gmail')]")).to be_present
      end

      it "is hidden without the pipeline on the plan (R45)" do
        stub_plan(pipeline: false)
        expect(mark_pitched_button).to be_nil
        expect(stream("update", "pitch_dialog").at_xpath(".//button[contains(., 'Regenerate')]")).to be_present
      end

      it "shows the stage instead once the deal has moved past pitched" do
        brand_match.update!(status: "replied")
        expect(mark_pitched_button).to be_nil
        expect(stream("update", "pitch_dialog").at_css("##{dom_id(brand_match, :mark_pitched)}").text).to include("Replied")
      end
    end

    describe "GET" do
      it "offers to write one when the match has no pitch yet" do
        get sponsor_match_pitch_path(brand_match), headers: turbo
        form = stream("update", "pitch_dialog").at_xpath(".//form[.//button[contains(., 'Write my pitch')]]")
        expect(form["action"]).to eq(sponsor_match_pitch_path(brand_match))
      end

      it "returns just one pitch's current state for the dialog to catch up on" do
        write_pitch
        pitch = Pitch.last
        get sponsor_match_pitch_path(brand_match, pitch_id: pitch.id), headers: turbo
        expect(stream("replace", dom_id(pitch)).at_css("[data-pitch-subject]")).to be_present
        expect(stream("update", "pitch_dialog")).to be_nil
      end

      it "renders the pack as a page without JavaScript" do
        write_pitch
        get sponsor_match_pitch_path(brand_match)
        expect(response).to have_http_status(:ok)
        expect(page.at_css("h1").text).to include("Fieldnote Coffee")
        expect(page.at_css("[data-pitch-subject]").text.squish).to eq(Pitch.last.subject)
      end

      it "shows a failed pitch's message with a way to try again" do
        Pitch.create!(sponsor_match: brand_match, status: "failed", error_message: Pitch::UNGROUNDED_MESSAGE)
        get sponsor_match_pitch_path(brand_match), headers: turbo
        dialog = stream("update", "pitch_dialog")
        expect(dialog.at_css("[role='alert']").text).to include(Pitch::UNGROUNDED_MESSAGE)
        expect(dialog.at_xpath(".//form[.//button[contains(., 'Try again')]]").at_css("input[name='regenerate']")).to be_present
      end

      it "shows a pitch stuck in the queue as failed rather than loading forever" do
        Pitch.create!(sponsor_match: brand_match, created_at: (Pitch::STALE_AFTER + 1.minute).ago)
        get sponsor_match_pitch_path(brand_match), headers: turbo
        dialog = stream("update", "pitch_dialog")
        expect(dialog.at_css(".skeleton")).to be_nil
        expect(dialog.at_css("[role='alert']").text).to include(Pitch::FAILURE_MESSAGE)
      end
    end

    describe "limits" do
      it "returns 402 with an upgrade dialog when the plan has no pitches" do
        stub_plan(pitches: 0)
        expect { post sponsor_match_pitch_path(brand_match), headers: turbo }.not_to change(Pitch, :count)

        expect(response).to have_http_status(:payment_required)
        expect(enqueued_jobs).to be_empty
        dialog = stream("update", "pitch_dialog")
        expect(dialog.at_css("dialog")).to be_present
        expect(dialog.at_css(".upgrade-prompt").text.squish).to include("Pitch packs are on Creator and up")
        expect(dialog.at_css("a[href='#{pricing_path}']")).to be_present
      end

      it "refuses a free user's pitch with 402 (R63)" do
        user.update!(judge: false)
        expect { post sponsor_match_pitch_path(brand_match), headers: turbo }.not_to change(Pitch, :count)
        expect(response).to have_http_status(:payment_required)
        expect(stream("update", "pitch_dialog").at_css("[data-upgrade-reason='plan']")).to be_present
      end

      it "checks the plan and inserts under the user's advisory lock (R61)" do
        allow(Pitch.connection).to receive(:execute).and_call_original
        post sponsor_match_pitch_path(brand_match), headers: turbo

        expect(Pitch.connection).to have_received(:execute)
          .with("SELECT pg_advisory_xact_lock(#{Entitlements::USAGE_LOCK_NAMESPACE}, #{user.id})")
      end

      it "returns 402 when the period's pitches are used up, in the open dialog on Regenerate" do
        write_pitch
        stub_plan(pitches: 1)
        expect { post sponsor_match_pitch_path(brand_match), params: { regenerate: 1 }, headers: turbo }.not_to change(Pitch, :count)

        expect(response).to have_http_status(:payment_required)
        pack = stream("replace", dom_id(brand_match, :pitch_pack))
        expect(pack.at_css(".upgrade-prompt").text.squish).to include("You've used 1 of 1 pitch this month")
        expect(pack.at_css("a[href='#{pricing_path}']")).to be_present
      end

      it "reserves pitches still being written: with 1 left, a second card gets 402 (R53)" do
        other = create(:sponsor_match, report: report, name: "Ramp")
        stub_plan(pitches: 1)

        post sponsor_match_pitch_path(brand_match), headers: turbo
        expect(response).to have_http_status(:ok)
        expect { post sponsor_match_pitch_path(other), headers: turbo }.not_to change(Pitch, :count)
        expect(response).to have_http_status(:payment_required)
      end

      it "shows the pitch a double-submit started while it waited for the lock, not a 402 (R61)" do
        stub_plan(pitches: 1)
        twin = nil
        # The other request took the lock first and committed its pitch while this one waited.
        allow(Entitlements).to receive(:lock_usage!).and_wrap_original do |original, locked_user|
          twin ||= Pitch.create!(sponsor_match: brand_match)
          original.call(locked_user)
        end

        expect { post sponsor_match_pitch_path(brand_match), headers: turbo }.not_to have_enqueued_job(GeneratePitchJob)
        expect(response).to have_http_status(:ok)
        expect(Pitch.pluck(:id)).to eq([ twin.id ])
        expect(stream("update", "pitch_dialog").at_css("[data-stream-catchup-url-value*='pitch_id=#{twin.id}']")).to be_present
      end

      it "doesn't reserve a pitch stuck in the queue" do
        other = create(:sponsor_match, report: report, name: "Ramp")
        Pitch.create!(sponsor_match: other, created_at: (Pitch::STALE_AFTER + 1.minute).ago)
        stub_plan(pitches: 1)

        expect { post sponsor_match_pitch_path(brand_match), headers: turbo }.to change(Pitch, :count).by(1)
        expect(response).to have_http_status(:ok)
      end

      it "writes pitches on an unlimited plan" do
        stub_plan(pitches: "unlimited")
        expect { post sponsor_match_pitch_path(brand_match), headers: turbo }.to change(Pitch, :count).by(1)
        expect(response).to have_http_status(:ok)
      end

      it "still shows a pitch already written when over the limit" do
        write_pitch
        stub_plan(pitches: 0)
        get sponsor_match_pitch_path(brand_match), headers: turbo
        expect(response).to have_http_status(:ok)
        expect(stream("update", "pitch_dialog").at_css("[data-pitch-subject]")).to be_present
      end

      context "when the LLM budget refuses" do
        before { allow(Llm).to receive(:mode).and_return(:live) }

        it "refuses with 402 and the pause's reason before queueing anything (R62)" do
          AppSettings.set(:runs_paused, true)
          AppSettings.set(:runs_paused_reason, "Back after a short maintenance break.")
          expect { post sponsor_match_pitch_path(brand_match), headers: turbo }.not_to change(Pitch, :count)

          expect(response).to have_http_status(:payment_required)
          prompt = stream("update", "pitch_dialog").at_css("[data-upgrade-reason='paused']")
          expect(prompt.text.squish).to eq("Back after a short maintenance break.")
        end

        it "refuses with 402 and today's capacity, not a waitlist, when the judge reserve is spent (R63a)" do
          allow(Llm::Budget).to receive(:allow?).with(:judge).and_return(false)
          post sponsor_match_pitch_path(brand_match), headers: turbo

          expect(response).to have_http_status(:payment_required)
          prompt = stream("update", "pitch_dialog").at_css("[data-upgrade-reason='budget']")
          expect(prompt.text.squish)
            .to eq("We've hit today's limit for pitch packs. Try again tomorrow. This didn't use any of your quota.")
          expect(prompt.at_css("a")).to be_nil
        end

        it "shows that pitches are paused when the budget refuses after queueing, records no charge and counts nothing" do
          post sponsor_match_pitch_path(brand_match), headers: turbo
          AppSettings.set(:runs_paused, true)
          perform_enqueued_jobs
          get sponsor_match_pitch_path(brand_match), headers: turbo

          expect(stream("update", "pitch_dialog").at_css("[role='alert']").text.squish).to include(paused)
          expect(SpendEntry.count).to eq(0)
          expect(Pitch.counted).to be_empty
          expect(RubyLLM::Test.requests).to be_empty
        end
      end
    end

    describe "access" do
      it "404s for another user's match" do
        other = create(:sponsor_match, name: "Secret Brand")
        with_production_errors do
          post sponsor_match_pitch_path(other), headers: turbo
          expect(response).to have_http_status(:not_found)
          sign_in user
          get sponsor_match_pitch_path(other), headers: turbo
          expect(response).to have_http_status(:not_found)
          expect(response.body).not_to include("Secret Brand")
        end
        expect(Pitch.count).to eq(0)
      end

      it "404s for a Snapshot match beyond the plan's visible limit, naming no brand (R43)" do
        snapshot = create(:report, show: show, kind: "snapshot", status: "done")
        visible = create(:sponsor_match, report: snapshot, position: 1, name: "Visible Brand")
        locked = create(:sponsor_match, report: snapshot, position: 2, name: "Locked Brand")
        Pitch.create!(sponsor_match: locked, status: "done", subject: "Locked subject", body: "Locked body")
        stub_plan(visible_matches: 1)

        with_production_errors do
          post sponsor_match_pitch_path(locked), headers: turbo
          expect(response).to have_http_status(:not_found)
          sign_in user
          get sponsor_match_pitch_path(locked, pitch_id: Pitch.last.id), headers: turbo
          expect(response).to have_http_status(:not_found)
          sign_in user
          get sponsor_match_pitch_path(locked)
          expect(response).to have_http_status(:not_found)
          expect(response.body).not_to include("Locked")
        end
        expect(Pitch.where(sponsor_match: locked).count).to eq(1)

        sign_in user
        post sponsor_match_pitch_path(visible), headers: turbo
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
