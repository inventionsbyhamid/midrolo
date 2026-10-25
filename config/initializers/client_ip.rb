# Which header says who the client is (R83). Behind our proxy (Traefik, on a private address Rack trusts), Rack reads
# the Forwarded header before X-Forwarded-For by default, and the proxy passes a client's own Forwarded header through
# untouched: anyone could pick their own IP (and with it their per-IP rate-limit bucket), host and scheme. Read only
# the X-Forwarded-* headers, which the proxy writes. This covers ActionDispatch's remote_ip as well as Rack's ip:
# Rails' RemoteIp middleware takes its list from Rack's forwarded_for, which follows this setting.
Rack::Request.forwarded_priority = [ :x_forwarded ]
