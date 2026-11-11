#!/usr/bin/env bash
# Installs the Debian packages that aren't installed yet, for CI. The runner images have most of them, and then apt doesn't run
# at all; when it must, it gives up on a mirror that doesn't answer after a few tries instead of retrying for ten minutes.
#
#   tools/ci_apt_install.sh <package>...

set -euo pipefail

missing=()
for package in "$@"; do
	if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
		missing+=("$package")
	fi
done
if [ ${#missing[@]} -eq 0 ]; then
	echo "Installed already: $*"
	exit 0
fi
echo "Installing: ${missing[*]}"

# The runners' DNS sometimes stops resolving Ubuntu's archive hosts while the hosts themselves are up. Then we look each one up
# with DNS over HTTPS at 1.1.1.1 (an address: no DNS needed to reach it) and pin it in /etc/hosts. Only on GitHub's runners:
# a developer's machine keeps its /etc/hosts.
if [ "${GITHUB_ACTIONS:-}" = true ]; then
	# The hosts apt uses: the mirror list, and the URIs: and deb lines of the sources (not their comments).
	hosts=$({ grep -hvE '^[[:space:]]*(#|$)' /etc/apt/apt-mirrors.txt 2>/dev/null
		grep -hE '^[[:space:]]*(URIs:|deb(-src)?[[:space:]])' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; } \
		| grep -oE '(https?://)?[a-z0-9.-]+\.ubuntu\.com' | sed -E 's|^https?://||' | sort -u || true)
	for host in $hosts; do
		if getent hosts "$host" >/dev/null; then
			continue
		fi
		address=$(curl -s --max-time 10 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=$host&type=A" \
			| jq -r '[.Answer[]? | select(.type == 1) | .data] | first // empty' || true)
		if [ -n "$address" ]; then
			echo "$host doesn't resolve: pinned to $address (DNS over HTTPS)"
			echo "$address $host" | sudo tee -a /etc/hosts >/dev/null
		else
			echo "$host doesn't resolve, and DNS over HTTPS has no address for it"
		fi
	done
fi

options=(-o Acquire::Retries=2 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20)
sudo apt-get "${options[@]}" update
sudo apt-get "${options[@]}" install -y --no-install-recommends "${missing[@]}"
