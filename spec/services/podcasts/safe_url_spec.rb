require "rails_helper"
require "socket"

# R131: midrolo-web shares Coolify's network with other production apps and fetches user-supplied feed URLs, so the
# DNS-rebinding window (check, then a second lookup at connect) is closed in code: a fetch connects to the address it
# vetted, with the hostname kept for the Host header, the TLS SNI and the certificate check.
RSpec.describe Podcasts::SafeUrl do
  describe "the blocklist" do
    before { allow(Resolv).to receive(:getaddresses).and_return([ "93.184.216.34" ]) }

    # NAT64 and 6to4 addresses embed an IPv4 one (here 10.0.0.1 and 127.0.0.1) that a gateway may route to.
    %w[http://[64:ff9b::a00:1]/feed http://[64:ff9b:1::a00:1]/feed http://[2002:7f00:1::1]/feed
       http://[2002:a9fe:a9fe::]/latest].each do |blocked|
      it "refuses #{blocked}" do
        expect { described_class.check!(blocked) }.to raise_error(described_class::Blocked, "internal address")
      end
    end

    it "refuses a host whose DNS answer is a NAT64 or 6to4 address" do
      allow(Resolv).to receive(:getaddresses).with("nat64.example.com").and_return([ "93.184.216.34", "64:ff9b::a9fe:a9fe" ])
      allow(Resolv).to receive(:getaddresses).with("sixtofour.example.com").and_return([ "2002:c0a8:101::1" ])

      expect(described_class).to be_blocked("https://nat64.example.com/feed")
      expect(described_class).to be_blocked("https://sixtofour.example.com/feed")
    end

    it "still allows an ordinary public IPv6 address" do
      expect(described_class.check!("https://[2606:2800:220:1:248:1893:25c8:1946]/feed").host).to eq("[2606:2800:220:1:248:1893:25c8:1946]")
    end
  end

  describe ".resolve!" do
    it "resolves the host once and gives the vetted address to connect to, IPv4 first" do
      allow(Resolv).to receive(:getaddresses).with("cdn.example.com").and_return([ "2606:2800:220:1::1", "93.184.216.34" ])

      target = described_class.resolve!("https://cdn.example.com/feed.xml")

      expect(target.uri.to_s).to eq("https://cdn.example.com/feed.xml")
      expect(target.address).to eq("93.184.216.34")
      expect(Resolv).to have_received(:getaddresses).once
    end

    it "connects to an IPv4-mapped literal by its IPv4 address" do
      expect(described_class.resolve!("http://[::ffff:5db8:d822]/feed").address).to eq("93.184.216.34")
    end
  end

  # Real sockets on loopback: WebMock is off, loopback and the test ports are let through the guard, and Resolv (the
  # guard's lookup) answers 127.0.0.1 for the test names. Any later lookup of a test name, the one Net::HTTP would make
  # at connect, is answered with an internal service's port instead: the rebinding attack.
  describe "connecting to the vetted address" do
    let(:hits) { Queue.new }
    let(:internal_hits) { Queue.new }
    let(:servers) { [] }

    around do |example|
      WebMock.disable!
      example.run
    ensure
      servers.each { |server| server.close rescue nil }
      WebMock.enable!
    end

    before do
      stub_const("Podcasts::SafeUrl::BLOCKED_RANGES",
                 Podcasts::SafeUrl::BLOCKED_RANGES.reject { |range| range.include?(IPAddr.new("127.0.0.1")) })
      allow(Resolv).to receive(:getaddresses).and_return([ "127.0.0.1" ])
    end

    def feed_xml = Rails.root.join("spec/fixtures/feeds/normal.xml").binread

    def response(body, type: "application/rss+xml")
      "HTTP/1.1 200 OK\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    end

    # Serves body to every request on 127.0.0.1, recording each request's head (and TLS SNI) in log. Returns the port.
    def serve(body, log:, tls: nil)
      tcp = TCPServer.new("127.0.0.1", 0)
      server = tls ? OpenSSL::SSL::SSLServer.new(tcp, tls) : tcp
      servers << server
      Thread.new do
        loop do
          socket = server.accept
          head = +""
          while (line = socket.gets) && line != "\r\n"
            head << line
          end
          log << head
          socket.write(response(body))
          socket.close
        rescue OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::EPIPE
          next
        rescue IOError
          break
        end
      end
      tcp.addr[1]
    end

    # The rebinding: a connect by name to a test host lands on the internal service.
    def rebind_names_to(internal_port)
      allow(TCPSocket).to receive(:open).and_wrap_original do |original, host, port, *rest, **options|
        if host.to_s.end_with?(".example.test")
          original.call("127.0.0.1", internal_port, *rest, **options)
        else
          original.call(host, port, *rest, **options)
        end
      end
    end

    def allow_ports(*ports) = stub_const("Podcasts::SafeUrl::ALLOWED_PORTS", [ 80, 443, *ports ])

    it "reads a feed from the vetted address, not from what the name resolves to at connect" do
      port = serve(feed_xml, log: hits)
      internal = serve("internal secrets", log: internal_hits)
      allow_ports(port, internal)
      rebind_names_to(internal)

      feed = Podcasts::FeedReader.new(cache: ActiveSupport::Cache::MemoryStore.new).read("http://feed.example.test:#{port}/feed.xml")

      expect(feed.warnings).to eq([])
      expect(feed.title).to eq("The Widget Hour")
      expect(hits.pop(timeout: 5)).to include("GET /feed.xml HTTP/1.1", "Host: feed.example.test:#{port}")
      expect(internal_hits).to be_empty
    end

    it "vets and pins every redirect hop the same way" do
      final = serve(feed_xml, log: hits)
      tcp = TCPServer.new("127.0.0.1", 0)
      servers << tcp
      first = tcp.addr[1]
      Thread.new do
        socket = tcp.accept
        head = +""
        while (line = socket.gets) && line != "\r\n"
          head << line
        end
        hits << head
        socket.write("HTTP/1.1 302 Found\r\nLocation: http://cdn.example.test:#{final}/moved.xml\r\nContent-Length: 0\r\n" \
                     "Connection: close\r\n\r\n")
        socket.close
      rescue IOError
        nil
      end
      internal = serve("internal secrets", log: internal_hits)
      allow_ports(first, final, internal)
      rebind_names_to(internal)

      feed = Podcasts::FeedReader.new(cache: ActiveSupport::Cache::MemoryStore.new).read("http://feed.example.test:#{first}/feed.xml")

      expect(feed.title).to eq("The Widget Hour")
      expect([ hits.pop(timeout: 5), hits.pop(timeout: 5) ].join).to include("Host: feed.example.test:#{first}", "Host: cdn.example.test:#{final}")
      expect(internal_hits).to be_empty
      expect(Resolv).to have_received(:getaddresses).with("cdn.example.test").at_least(:once)
    end

    it "fetches share artwork from the vetted address too" do
      port = serve(Rails.root.join("spec/fixtures/files/cover.png").binread, log: hits)
      internal = serve("internal secrets", log: internal_hits)
      allow_ports(port, internal)
      rebind_names_to(internal)

      png = ShareImages::Artwork.fetch("http://art.example.test:#{port}/cover.png", size: 64)

      expect(Vips::Image.pngload_buffer(png).width).to eq(64)
      expect(hits.pop(timeout: 5)).to include("Host: art.example.test:#{port}")
      expect(internal_hits).to be_empty
    end

    describe "over TLS" do
      let(:ca_key) { OpenSSL::PKey::EC.generate("prime256v1") }
      let(:ca) do
        cert = certificate(subject: "/CN=Midrolo spec CA", key: ca_key, issuer: nil, issuer_key: ca_key)
        extensions = OpenSSL::X509::ExtensionFactory.new(cert, cert)
        cert.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
        cert.add_extension(extensions.create_extension("keyUsage", "keyCertSign, cRLSign", true))
        cert.sign(ca_key, OpenSSL::Digest.new("SHA256"))
        cert
      end
      let(:snis) { Queue.new }

      def certificate(subject:, key:, issuer:, issuer_key:, san: nil)
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = SecureRandom.random_number(2**64)
        cert.subject = OpenSSL::X509::Name.parse(subject)
        cert.issuer = issuer ? issuer.subject : cert.subject
        cert.public_key = key
        cert.not_before = 1.hour.ago
        cert.not_after = 1.hour.from_now
        if san
          extensions = OpenSSL::X509::ExtensionFactory.new(issuer, cert)
          cert.add_extension(extensions.create_extension("subjectAltName", san))
          cert.sign(issuer_key, OpenSSL::Digest.new("SHA256"))
        end
        cert
      end

      # A TLS context whose certificate, signed by the spec CA, names san. Records the SNI each client sends.
      def tls(san)
        key = OpenSSL::PKey::EC.generate("prime256v1")
        context = OpenSSL::SSL::SSLContext.new
        context.cert = certificate(subject: "/CN=spec", key: key, issuer: ca, issuer_key: ca_key, san: san)
        context.key = key
        context.servername_cb = lambda do |(_socket, name)|
          snis << name
          nil
        end
        context
      end

      # The client trusts the spec CA (and the system ones) wherever it builds a certificate store.
      before do
        allow(OpenSSL::X509::Store).to receive(:new).and_wrap_original { |original, *args| original.call(*args).tap { |store| store.add_cert(ca) } }
      end

      it "sends the hostname as SNI and verifies the certificate against it while connecting to the vetted address" do
        port = serve(feed_xml, log: hits, tls: tls("DNS:feed.example.test"))
        internal = serve("internal secrets", log: internal_hits)
        allow_ports(port, internal)
        rebind_names_to(internal)

        feed = Podcasts::FeedReader.new(cache: ActiveSupport::Cache::MemoryStore.new).read("https://feed.example.test:#{port}/feed.xml")

        expect(feed.title).to eq("The Widget Hour")
        expect(snis.pop(timeout: 5)).to eq("feed.example.test")
        expect(hits.pop(timeout: 5)).to include("Host: feed.example.test:#{port}")
        expect(internal_hits).to be_empty
      end

      it "refuses a certificate that names only the address it connected to, not the hostname" do
        port = serve(feed_xml, log: hits, tls: tls("IP:127.0.0.1"))
        allow_ports(port)

        feed = Podcasts::FeedReader.new(cache: ActiveSupport::Cache::MemoryStore.new).read("https://feed.example.test:#{port}/feed.xml")

        expect(feed.warnings).to eq([ "feed_unreadable" ])
        expect(snis.pop(timeout: 5)).to eq("feed.example.test") # it reached the vetted address, then refused the certificate
        expect(hits).to be_empty
      end
    end
  end
end
