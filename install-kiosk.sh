#!/bin/sh
# Turns a fresh, minimal Debian 13 into a DoelDisplay player: cage with Chromium on tty1, showing
# /d/ and recovering by itself. This is steps 1 to 15 of docs/linux-kiosk-installatie.md in one go;
# the why is in docs/linux-kiosk.md. Step 0 (the BIOS, installing Debian with the profile
# partition) still happens at the machine, and pairing still happens in the dashboard.
#
#   curl -fsSL https://<wherever it is hosted>/install-kiosk.sh -o install-kiosk.sh
#   sudo sh install-kiosk.sh --url https://display.dedoelen.nl/d/
#
# Safe to run again: a file that is already right is left alone, KIOSK_CHROMIUM_FLAGS in
# /etc/default/doeldisplay-kiosk is kept, and the kiosk restarts with whatever --url says now.
# --dry-run prints what it would do and changes nothing. Everything runs from main() on the last
# line, so a download that breaks off halfway runs nothing at all.
#
# The files it writes are the ones in the installation document. A change to one is a change to
# both.
set -eu

KIOSK_URL=
NTP_SERVER=
ROOT_CA=
WITH_I965=0
WITH_SSH=1
START=1
DRY_RUN=0
WARNINGS=
SSH_HARDENED=0

usage() {
	cat <<'EOF'
Usage: sudo sh install-kiosk.sh --url https://<server>/d/ [options]

  --url URL        the page the player shows (required), e.g. https://display.dedoelen.nl/d/
  --ntp HOST       the building's NTP server (default: the Debian pool, UDP 123 outbound)
  --root-ca FILE   the server's root certificate; only with PROXY_TLS=internal (step 14)
  --i965           also install i965-va-driver, for an Intel GPU older than 8th generation
  --no-ssh         leave the SSH configuration alone (step 1)
  --no-start       enable the kiosk, but let it start at the next boot instead of now
  --dry-run        print what would be done, change nothing
  -h, --help       this text
EOF
}

say() { printf '%s\n' "$*"; }
section() { printf '\n==> %s\n' "$*"; }
die() {
	printf 'install-kiosk: %s\n' "$*" >&2
	exit 1
}
warn() {
	printf '    warning: %s\n' "$*" >&2
	WARNINGS="${WARNINGS}  - $*
"
}

run() {
	if [ "$DRY_RUN" = 1 ]; then
		say "+ $*"
	else
		"$@"
	fi
}

as_kiosk() { run runuser -u kiosk -- "$@"; }

apt_get() {
	run env DEBIAN_FRONTEND=noninteractive apt-get -y \
		-o DPkg::Lock::Timeout=600 \
		-o Dpkg::Options::=--force-confdef \
		-o Dpkg::Options::=--force-confold \
		"$@"
}

# put FILE MODE: writes stdin to FILE, unless FILE already holds exactly that.
put() {
	put_tmp=$(mktemp)
	cat >"$put_tmp"
	if [ -f "$1" ] && cmp -s "$put_tmp" "$1"; then
		rm -f "$put_tmp"
		say "    unchanged $1"
		return 0
	fi
	if [ "$DRY_RUN" = 1 ]; then
		rm -f "$put_tmp"
		say "+ write $1"
		return 0
	fi
	mkdir -p "$(dirname "$1")"
	chmod "$2" "$put_tmp"
	mv "$put_tmp" "$1"
	say "    wrote $1"
}

# The first time this script edits a file it did not write, the original goes to /var/backups.
# Not next to it: apt complains about every unknown file in sources.list.d.
backup() {
	backup_to=/var/backups/doeldisplay-kiosk$1
	if [ -f "$1" ] && [ ! -e "$backup_to" ]; then
		run mkdir -p "$(dirname "$backup_to")"
		run cp -a "$1" "$backup_to"
	fi
}

parse_args() {
	while [ $# -gt 0 ]; do
		case $1 in
		--url | --ntp | --root-ca)
			[ $# -ge 2 ] || die "$1 needs a value"
			case $1 in
			--url) KIOSK_URL=$2 ;;
			--ntp) NTP_SERVER=$2 ;;
			--root-ca) ROOT_CA=$2 ;;
			esac
			shift 2
			;;
		--url=*) KIOSK_URL=${1#*=}; shift ;;
		--ntp=*) NTP_SERVER=${1#*=}; shift ;;
		--root-ca=*) ROOT_CA=${1#*=}; shift ;;
		--i965) WITH_I965=1; shift ;;
		--no-ssh) WITH_SSH=0; shift ;;
		--no-start) START=0; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die "unknown option: $1" ;;
		esac
	done

	[ -n "$KIOSK_URL" ] || { usage >&2; die "--url is required"; }
	# It ends up in a JSON policy and an EnvironmentFile, so nothing that needs quoting.
	case $KIOSK_URL in
	*[[:space:]\"\'\\\`\$]*) die "--url contains a character that cannot go in the configuration: $KIOSK_URL" ;;
	https://?*) ;;
	*) die "--url must start with https:// (the service worker and the pairing need TLS): $KIOSK_URL" ;;
	esac
	SERVER_ORIGIN=$(printf '%s\n' "$KIOSK_URL" | sed -E 's|^(https://[^/?#]+).*|\1|')
	SERVER_HOST=${SERVER_ORIGIN#https://}
	SERVER_HOST=${SERVER_HOST%%:*}

	if [ -n "$NTP_SERVER" ]; then
		case $NTP_SERVER in
		*[!A-Za-z0-9.:-]*) die "--ntp is not a host name: $NTP_SERVER" ;;
		esac
	fi
	if [ -n "$ROOT_CA" ]; then
		[ -r "$ROOT_CA" ] || die "--root-ca: cannot read $ROOT_CA"
		grep -q 'BEGIN CERTIFICATE' "$ROOT_CA" || die "--root-ca: $ROOT_CA is not a PEM certificate"
	fi
}

preflight() {
	if [ "$(id -u)" != 0 ]; then
		[ "$DRY_RUN" = 1 ] || die "run this as root: sudo sh $0 ..."
	fi
	[ -r /etc/os-release ] || die "no /etc/os-release: this is not Debian"
	# shellcheck disable=SC1091 # only exists on the target
	os_id=$(. /etc/os-release && printf '%s' "${ID:-}")
	# shellcheck disable=SC1091
	os_version=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
	[ "$os_id" = debian ] || die "this is $os_id, not Debian"
	[ "$os_version" = 13 ] || warn "this is Debian $os_version; the steps are written for Debian 13"
	arch=$(dpkg --print-architecture)
	[ "$arch" = amd64 ] || die "this is $arch; a player is x86-64 (docs/linux-kiosk.md chapter 2)"
	if [ ! -d /run/systemd/system ]; then
		[ "$DRY_RUN" = 1 ] || die "systemd is not running"
		warn "systemd is not running"
	fi
	say "Player for $KIOSK_URL"
	[ "$DRY_RUN" = 0 ] || say "Dry run: nothing is changed."
}

step_ssh() {
	section "1. SSH: keys only"
	if [ "$WITH_SSH" = 0 ]; then
		say "    skipped (--no-ssh)"
		return 0
	fi
	if ! command -v sshd >/dev/null 2>&1; then
		warn "no SSH server installed; SSH left alone"
		return 0
	fi
	# Password login only goes off when the account running this already has a key, or the next
	# login would be impossible.
	admin=${SUDO_USER:-}
	if [ -z "$admin" ] || [ "$admin" = root ]; then
		warn "not run through sudo, so it is unclear whose key to check; password login stays on (run with sudo from your own account, or do step 1 by hand)"
		return 0
	fi
	admin_home=$(getent passwd "$admin" | cut -d: -f6)
	if ! grep -Eqs '^[[:space:]]*(ssh|ecdsa|sk-)' "$admin_home/.ssh/authorized_keys"; then
		warn "$admin has no key in $admin_home/.ssh/authorized_keys; password login stays on. Run ssh-copy-id $admin@$(hostname) from your own computer and run this script again"
		return 0
	fi
	put /etc/ssh/sshd_config.d/10-doeldisplay.conf 644 <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
	# sshd -t wants the directory the service creates on start, and ssh may not have started yet.
	[ "$DRY_RUN" = 1 ] || mkdir -p /run/sshd
	if [ "$DRY_RUN" = 0 ] && ! sshd -t; then
		rm -f /etc/ssh/sshd_config.d/10-doeldisplay.conf
		die "sshd -t rejects the configuration; removed it again"
	fi
	run systemctl reload ssh
	SSH_HARDENED=1
}

step_sources() {
	section "2. Package sources and updates"
	if ! grep -rqsE '^[^#]*non-free-firmware' /etc/apt/sources.list /etc/apt/sources.list.d/; then
		say "    adding non-free-firmware (firmware for the Intel GPU and some network cards)"
		for f in /etc/apt/sources.list.d/*.sources; do
			[ -f "$f" ] || continue
			backup "$f"
			run sed -i -E '/^Components:/{/non-free-firmware/!s/$/ non-free-firmware/}' "$f"
		done
		if [ -f /etc/apt/sources.list ]; then
			backup /etc/apt/sources.list
			run sed -i -E '/^deb(-src)?[[:space:]]/{/non-free-firmware/!s/[[:space:]]main([[:space:]]|$)/ main non-free-firmware\1/}' /etc/apt/sources.list
		fi
		if [ "$DRY_RUN" = 0 ] && ! grep -rqsE '^[^#]*non-free-firmware' /etc/apt/sources.list /etc/apt/sources.list.d/; then
			die "could not add non-free-firmware to the package sources; add it to the line(s) with main by hand and run this again"
		fi
	fi
	apt_get update
	apt_get full-upgrade
}

step_packages() {
	section "3. Packages"
	extra=
	[ "$WITH_I965" = 0 ] || extra=i965-va-driver
	# shellcheck disable=SC2086 # $extra is empty or one package
	apt_get install \
		cage chromium fonts-dejavu-core \
		intel-media-va-driver vainfo intel-gpu-tools firmware-misc-nonfree \
		wlr-randr grim ddcutil \
		unattended-upgrades apt-listchanges systemd-timesyncd \
		libnss3-tools ethtool $extra
}

step_profile_partition() {
	section "4. The profile partition"
	options=defaults,noatime,nofail,x-systemd.device-timeout=10s
	if ! findmnt -n /var/lib/kiosk >/dev/null 2>&1; then
		warn "/var/lib/kiosk is not a separate partition, so it becomes a plain directory and a reinstall loses the pairing. If 'lsblk -f' shows an ext4 partition without a mount point, put it in /etc/fstab by its UUID with the options $options and run this again"
		return 0
	fi
	current=$(awk '$1 !~ /^#/ && $2 == "/var/lib/kiosk" { print $4 }' /etc/fstab)
	if [ -z "$current" ]; then
		warn "/var/lib/kiosk is mounted but not in /etc/fstab; set its options to $options by hand"
		return 0
	fi
	if [ "$current" = "$options" ]; then
		say "    unchanged /etc/fstab"
	else
		backup /etc/fstab
		if [ "$DRY_RUN" = 1 ]; then
			say "+ /etc/fstab: options for /var/lib/kiosk from $current to $options"
		else
			fstab_tmp=$(mktemp)
			awk -v o="$options" 'BEGIN { OFS = "\t" } $1 !~ /^#/ && $2 == "/var/lib/kiosk" { $4 = o } { print }' /etc/fstab >"$fstab_tmp"
			cat "$fstab_tmp" >/etc/fstab
			rm -f "$fstab_tmp"
			say "    /etc/fstab: options for /var/lib/kiosk set to $options"
		fi
		run systemctl daemon-reload
		run mount -o remount /var/lib/kiosk
	fi
	[ "$DRY_RUN" = 1 ] || say "    $(findmnt -n -o TARGET,OPTIONS /var/lib/kiosk)"
}

step_user() {
	section "5. The user kiosk"
	# On a minimal install not every group exists, and useradd then makes no user at all.
	for g in video render input; do
		getent group "$g" >/dev/null || run groupadd --system "$g"
	done
	if id kiosk >/dev/null 2>&1; then
		run usermod -a -G video,render,input kiosk
	else
		run useradd --system --home-dir /var/lib/kiosk --shell /usr/sbin/nologin \
			--groups video,render,input kiosk
	fi
	run mkdir -p /var/lib/kiosk
	run chown kiosk:kiosk /var/lib/kiosk
	run chmod 700 /var/lib/kiosk
	[ "$DRY_RUN" = 1 ] || say "    $(id kiosk)"
}

step_policy() {
	section "6. The Chromium policy"
	put /etc/chromium/policies/managed/doeldisplay.json 644 <<EOF
{
  "URLBlocklist": ["*"],
  "URLAllowlist": ["$SERVER_HOST", "about:blank"],
  "TranslateEnabled": false,
  "PasswordManagerEnabled": false,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false,
  "DefaultNotificationsSetting": 2,
  "NotificationsAllowedForUrls": ["$SERVER_ORIGIN"],
  "DefaultGeolocationSetting": 2,
  "BrowserSignin": 0,
  "SyncDisabled": true,
  "MetricsReportingEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "HardwareAccelerationModeEnabled": true,
  "DeveloperToolsAvailability": 2
}
EOF
}

step_service() {
	section "7. The start script and the service"
	flags=
	if [ -f /etc/default/doeldisplay-kiosk ]; then
		flags=$(sed -n 's/^KIOSK_CHROMIUM_FLAGS=//p' /etc/default/doeldisplay-kiosk | tail -n 1)
	fi
	put /etc/default/doeldisplay-kiosk 644 <<EOF
KIOSK_URL=$KIOSK_URL
# Extra Chromium-vlaggen, bijvoorbeeld voor video in hardware (stap 13):
KIOSK_CHROMIUM_FLAGS=$flags
EOF

	put /usr/local/bin/doeldisplay-kiosk 755 <<'EOF'
#!/bin/sh
# Start cage met Chromium op één pagina.
set -eu

PROFILE=/var/lib/kiosk/chromium
PREFS="$PROFILE/Default/Preferences"

# Na een stroomstoring markeert Chromium zijn vorige sessie als gecrasht en biedt hij aan die te
# herstellen. Op een kiosk is er niemand om dat weg te klikken.
if [ -f "$PREFS" ]; then
  sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"[^"]*"/"exit_type":"Normal"/' "$PREFS"
fi

# shellcheck disable=SC2086 # KIOSK_CHROMIUM_FLAGS is bewust een lijst losse vlaggen
exec /usr/bin/cage -d -- /usr/bin/chromium \
  --ozone-platform=wayland \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --disable-session-crashed-bubble \
  --autoplay-policy=no-user-gesture-required \
  --password-store=basic \
  --user-data-dir="$PROFILE" \
  ${KIOSK_CHROMIUM_FLAGS:-} \
  "$KIOSK_URL"
EOF

	put /etc/pam.d/doeldisplay-kiosk 644 <<'EOF'
auth     required pam_unix.so nullok
account  required pam_unix.so
session  required pam_unix.so
session  required pam_systemd.so
EOF

	put /etc/systemd/system/doeldisplay-kiosk.service 644 <<'EOF'
[Unit]
Description=DoelDisplay-kiosk (cage met Chromium) op tty1
After=systemd-user-sessions.service plymouth-quit-wait.service
Wants=dbus.socket systemd-logind.service
After=dbus.socket systemd-logind.service
Conflicts=getty@tty1.service
After=getty@tty1.service
ConditionPathExists=/dev/tty1

[Service]
Type=simple
User=kiosk
EnvironmentFile=/etc/default/doeldisplay-kiosk
ExecStart=/usr/local/bin/doeldisplay-kiosk
Restart=always
RestartSec=2
PAMName=doeldisplay-kiosk
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-fail
StandardOutput=journal
StandardError=journal
UtmpIdentifier=tty1
UtmpMode=user

[Install]
WantedBy=multi-user.target
EOF
	run systemctl daemon-reload
	if [ "$DRY_RUN" = 0 ] && ! systemd-analyze verify /etc/systemd/system/doeldisplay-kiosk.service; then
		warn "systemd-analyze verify complains about doeldisplay-kiosk.service (see above)"
	fi
}

step_boot() {
	section "8. Booting without questions"
	if [ -f /etc/default/grub ] && command -v update-grub >/dev/null 2>&1; then
		backup /etc/default/grub
		run sed -i \
			-e 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' \
			-e 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet fsck.repair=yes panic=10"/' \
			/etc/default/grub
		run update-grub
	else
		warn "no GRUB: set a boot timeout of 0 and 'fsck.repair=yes panic=10' on the kernel command line by hand"
	fi
	run systemctl mask ctrl-alt-del.target
}

step_watchdog() {
	section "9. The hardware watchdog"
	if [ ! -e /dev/watchdog0 ] && [ ! -e /dev/watchdog ]; then
		# iTCO_wdt on Intel, sp5100_tco on AMD, i6300esb in a VM (docs/linux-kiosk.md chapter 13).
		for module in iTCO_wdt sp5100_tco i6300esb; do
			if [ "$DRY_RUN" = 1 ]; then
				say "+ modprobe $module (until one gives /dev/watchdog0)"
				break
			fi
			modprobe "$module" 2>/dev/null || continue
			udevadm settle 2>/dev/null || true
			if [ -e /dev/watchdog0 ] || [ -e /dev/watchdog ]; then
				printf '%s\n' "$module" | put /etc/modules-load.d/watchdog.conf 644
				break
			fi
			modprobe -r "$module" 2>/dev/null || true
		done
	fi
	if [ "$DRY_RUN" = 0 ] && [ ! -e /dev/watchdog0 ] && [ ! -e /dev/watchdog ]; then
		warn "no hardware watchdog found; panic=10 still catches a kernel panic, but not a machine that hangs without one. Note this for the model"
		return 0
	fi
	put /etc/systemd/system.conf.d/watchdog.conf 644 <<'EOF'
[Manager]
RuntimeWatchdogSec=30s
RebootWatchdogSec=2min
EOF
	run systemctl daemon-reexec
	if [ "$DRY_RUN" = 0 ]; then
		say "    $(systemctl show --property=RuntimeWatchdogUSec)"
		say "    check the timeout the hardware accepts with: sudo wdctl"
	fi
}

step_clock() {
	section "10. The clock"
	run timedatectl set-timezone Europe/Amsterdam
	if [ -n "$NTP_SERVER" ]; then
		put /etc/systemd/timesyncd.conf.d/gebouw.conf 644 <<EOF
[Time]
NTP=$NTP_SERVER
EOF
		run systemctl restart systemd-timesyncd
	elif [ ! -f /etc/systemd/timesyncd.conf.d/gebouw.conf ]; then
		say "    no --ntp: the Debian pool, so UDP 123 outbound has to be open"
	fi
}

step_updates() {
	section "11. Nightly updates and the daily reboot"
	put /etc/apt/apt.conf.d/20auto-upgrades 644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
	uu=/etc/apt/apt.conf.d/50unattended-upgrades
	if [ -f "$uu" ] && ! grep -Eq '^[[:space:]]*"[^"]*label=Debian-Security' "$uu"; then
		warn "$uu has no active Debian-Security line, so security updates are not installed automatically"
	fi

	put /etc/systemd/system/apt-daily.timer.d/doeldisplay.conf 644 <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=10m
EOF
	put /etc/systemd/system/apt-daily-upgrade.timer.d/doeldisplay.conf 644 <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:45:00
RandomizedDelaySec=10m
EOF

	put /etc/systemd/system/doeldisplay-reboot.service 644 <<'EOF'
[Unit]
Description=Dagelijkse herstart van de speler

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl reboot
EOF
	put /etc/systemd/system/doeldisplay-reboot.timer 644 <<'EOF'
[Unit]
Description=Dagelijkse herstart van de speler om 04:30

[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=false

[Install]
WantedBy=timers.target
EOF
	run systemctl daemon-reload
	run systemctl enable --now doeldisplay-reboot.timer
}

step_journal() {
	section "12. The journal and /tmp"
	put /etc/systemd/journald.conf.d/doeldisplay.conf 644 <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
	run systemctl restart systemd-journald
	if [ "$(findmnt -n -o FSTYPE /tmp 2>/dev/null || true)" != tmpfs ]; then
		warn "/tmp is not in memory; 'sudo systemctl enable tmp.mount' and reboot"
	fi
}

step_video() {
	section "13. Video in hardware"
	if [ "$DRY_RUN" = 1 ]; then
		say "    (checks vainfo for an H.264 decoder)"
		return 0
	fi
	if [ ! -e /dev/dri/renderD128 ]; then
		warn "no /dev/dri/renderD128: no GPU for cage and VA-API (in a VM: virtio-gpu, not the standard VGA)"
	elif vainfo --display drm --device /dev/dri/renderD128 2>/dev/null |
		grep -Eq 'VAProfileH264High[[:space:]]*:[[:space:]]*VAEntrypointVLD'; then
		say "    the GPU decodes H.264 (VAProfileH264High, VAEntrypointVLD)"
	else
		warn "vainfo lists no H.264 decoder; video is decoded in software. Older than 8th-generation Intel: run again with --i965"
	fi
	say "    whether Chromium uses it is measured with a video playing: step 13 of the installation document"
}

step_root_ca() {
	[ -n "$ROOT_CA" ] || return 0
	section "14. The root certificate (PROXY_TLS=internal)"
	nssdb=/var/lib/kiosk/.local/share/pki/nssdb
	ca_tmp=$(mktemp)
	cp "$ROOT_CA" "$ca_tmp"
	chmod 644 "$ca_tmp"
	as_kiosk mkdir -p "$nssdb"
	[ -f "$nssdb/cert9.db" ] || as_kiosk certutil -d "sql:$nssdb" -N --empty-password
	# A run with a new certificate replaces the old one under the same name.
	as_kiosk certutil -d "sql:$nssdb" -D -n doeldisplay 2>/dev/null || true
	as_kiosk certutil -d "sql:$nssdb" -A -t "C,," -n doeldisplay -i "$ca_tmp"
	rm -f "$ca_tmp"
	[ "$DRY_RUN" = 1 ] || as_kiosk certutil -d "sql:$nssdb" -L
}

step_start() {
	section "15. Starting"
	run systemctl enable doeldisplay-kiosk.service
	if [ "$START" = 1 ]; then
		# A restart, so a second run with another --url shows it straight away.
		run systemctl restart doeldisplay-kiosk.service
		[ "$DRY_RUN" = 1 ] || systemctl --no-pager --lines=0 status doeldisplay-kiosk.service || true
	else
		say "    not started (--no-start): it starts at the next boot"
	fi
}

summary() {
	section "Done"
	if [ -n "$WARNINGS" ]; then
		say "Look at these:"
		printf '%s' "$WARNINGS"
		say ""
	fi
	if [ "$SSH_HARDENED" = 1 ]; then
		say "SSH now takes keys only. Open a SECOND session and log in before you close this one."
		say ""
	fi
	say "Next:"
	say "  1. The screen shows 'Scherm koppelen' with a code: pair it in the dashboard (docs/runbook.md, step 4.8)."
	say "  2. sudo reboot: GRUB, the kernel command line and the watchdog take effect then."
	say "  3. Go through the checklist in step 15 of docs/linux-kiosk-installatie.md."
}

main() {
	parse_args "$@"
	preflight
	step_ssh
	step_sources
	step_packages
	step_profile_partition
	step_user
	step_policy
	step_service
	step_boot
	step_watchdog
	step_clock
	step_updates
	step_journal
	step_video
	step_root_ca
	step_start
	summary
}

main "$@"
