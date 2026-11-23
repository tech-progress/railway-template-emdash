#!/bin/sh
# EmDash public gateway (Caddy), the template's only public service. The site,
# its media and EmDash's token-authenticated REST and MCP APIs stay public.
# The admin panel and the first-run setup API need HTTP Basic credentials,
# because until setup is complete EmDash lets the first visitor create the
# admin account. Requests whose path could be read differently by Caddy and
# by the Node server are refused. The plaintext password is hashed and
# removed from the environment, and a Basic credential is never forwarded.
set -eu

fail() { echo "gateway-start: $*" >&2; exit 64; }

for name in PORT GATEWAY_USERNAME GATEWAY_PASSWORD GATEWAY_ADMIN_GATE EMDASH_APP_ADDRESS GATEWAY_TRUSTED_PROXIES; do
  eval "value=\${${name}:-}"
  [ -n "${value}" ] || fail "${name} is required"
done
case "${PORT}" in *[!0-9]*) fail "PORT must be numeric" ;; esac
case "${GATEWAY_USERNAME}" in *[!A-Za-z0-9._-]*) fail "GATEWAY_USERNAME may contain only letters, digits, dot, underscore and hyphen" ;; esac
case "${GATEWAY_PASSWORD}" in *[!A-Za-z0-9]*) fail "GATEWAY_PASSWORD may contain only letters and digits" ;; esac
[ "${#GATEWAY_PASSWORD}" -ge 16 ] || fail "GATEWAY_PASSWORD must have 16 or more characters"
case "${EMDASH_APP_ADDRESS}" in *[!A-Za-z0-9.:-]* | *:) fail "invalid EMDASH_APP_ADDRESS ${EMDASH_APP_ADDRESS}" ;; esac
case "${EMDASH_APP_ADDRESS}" in *:[0-9]*) ;; *) fail "EMDASH_APP_ADDRESS needs a port" ;; esac
case "${GATEWAY_TRUSTED_PROXIES}" in *[!0-9a-fA-F.:/\ ]*) fail "GATEWAY_TRUSTED_PROXIES must be CIDR ranges" ;; esac
# "admin" gates the admin panel and the setup API; "setup" gates only the
# setup API, which EmDash itself closes once setup is complete.
case "${GATEWAY_ADMIN_GATE}" in
  admin) gated_paths="/_emdash/admin* /_emdash/api/setup*" ;;
  setup) gated_paths="/_emdash/api/setup*" ;;
  *) fail "GATEWAY_ADMIN_GATE must be admin or setup" ;;
esac

password_hash="$(printf '%s\n' "${GATEWAY_PASSWORD}" | caddy hash-password)"
unset GATEWAY_PASSWORD
case "${password_hash}" in '$2a$'*) ;; *) fail "could not hash GATEWAY_PASSWORD" ;; esac

umask 077
config="$(mktemp -d /tmp/emdash-gateway.XXXXXX)/Caddyfile"
cat >"${config}" <<EOF
{
	admin off
	auto_https off
	persist_config off
	servers {
		trusted_proxies static ${GATEWAY_TRUSTED_PROXIES}
		client_ip_headers X-Real-IP
	}
}

:${PORT} {
	header {
		X-Content-Type-Options nosniff
		-Server
	}

	# Railway's edge terminates TLS and sets X-Forwarded-Proto: https.
	map {http.request.header.X-Forwarded-Proto} {forwarded_proto} {
		https https
		default {http.request.scheme}
	}

	# Paths that Caddy and the Node server could resolve differently: an
	# encoded dot, slash, backslash or NUL in the path, a raw backslash, an
	# empty segment, or a dot segment. Browsers never send these for links
	# the site generates. The raw request target is checked before any
	# decoding or dot-segment removal.
	@ambiguous {
		vars_regexp raw {http.request.uri} (?i)^[^?#]*(%2e|%2f|%5c|%00|\\\\|//|/\.\.?(/|\?|#|$))
	}
	@notorigin not vars_regexp origin {http.request.uri} ^/
	@gated path ${gated_paths}
	@basiccredential header_regexp Authorization (?i)^basic(\s|$)

	route {
		handle /__gateway/health {
			respond "ok" 200
		}
		handle @notorigin {
			respond "Bad Request" 400
		}
		handle @ambiguous {
			respond "Bad Request" 400
		}
		handle @gated {
			basic_auth bcrypt EmDash {
				${GATEWAY_USERNAME} ${password_hash}
			}
			request_header -Authorization
			reverse_proxy ${EMDASH_APP_ADDRESS} {
				header_up X-Real-IP {client_ip}
				header_up X-Forwarded-Proto {forwarded_proto}
			}
		}
		handle {
			# EmDash's APIs use Bearer tokens; a browser that signed in to the
			# admin panel may still attach the gateway's Basic credential.
			request_header @basiccredential -Authorization
			reverse_proxy ${EMDASH_APP_ADDRESS} {
				header_up X-Real-IP {client_ip}
				header_up X-Forwarded-Proto {forwarded_proto}
			}
		}
	}
}
EOF

caddy validate --config "${config}" --adapter caddyfile >/dev/null 2>&1 || fail "generated Caddyfile is invalid"
exec caddy run --config "${config}" --adapter caddyfile
