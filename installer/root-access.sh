#!/bin/sh
# Applied to the installed system; does not change the installer host.
set -eu
root=${1:-/target}
[ -f "$root/etc/ssh/sshd_config" ] || { echo 'Installed SSH configuration is missing' >&2; exit 1; }
[ -f "$root/etc/pam.d/gdm-autologin" ] || { echo 'Installed GDM autologin configuration is missing' >&2; exit 1; }
[ -f "$root/etc/pam.d/gdm-password" ] || { echo 'Installed GDM password configuration is missing' >&2; exit 1; }
mkdir -p "$root/etc/ssh/sshd_config.d"
cat > "$root/etc/ssh/sshd_config.d/00-library-root.conf" <<'EOF'
# Library installation: password-authenticated root SSH access.
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
EOF
# Debian normally includes this directory already. Preserve configurations lacking the Include.
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config[.]d/[*][.]conf' "$root/etc/ssh/sshd_config"; then
    { echo 'Include /etc/ssh/sshd_config.d/*.conf'; cat "$root/etc/ssh/sshd_config"; } > "$root/etc/ssh/sshd_config.library-new"
    cat "$root/etc/ssh/sshd_config.library-new" > "$root/etc/ssh/sshd_config"
    rm "$root/etc/ssh/sshd_config.library-new"
fi
for service in gdm-password gdm-autologin; do
pam="$root/etc/pam.d/$service"
[ -f "$pam.library-original" ] || cp -p "$pam" "$pam.library-original"
# Remove only GDM's root exclusion, retaining normal password and session checks.
awk '
    /^[[:space:]]*auth[[:space:]]/ && /pam_succeed_if[.]so/ && /user[[:space:]]*!=[[:space:]]*root([[:space:]]|$)/ {
        print "# Library root GUI login: " $0
        next
    }
    { print }
' "$pam" > "$pam.library-new"
cat "$pam.library-new" > "$pam"
rm "$pam.library-new"
done
mkdir -p "$root/etc/gdm3"
config="$root/etc/gdm3/daemon.conf"
[ -f "$config" ] || touch "$config"
[ -f "$config.library-original" ] || cp -p "$config" "$config.library-original"
awk '
    /^[[:space:]]*\[/ {
        daemon = ($0 ~ /^[[:space:]]*\[daemon\][[:space:]]*$/)
        print
        if (daemon) {
            found = 1
            print "AutomaticLoginEnable=true"
            print "AutomaticLogin=root"
            print "TimedLoginEnable=false"
        }
        next
    }
    daemon && /^[[:space:]#;]*(AutomaticLoginEnable|AutomaticLogin|TimedLoginEnable|TimedLogin)[[:space:]]*=/ { next }
    { print }
    END {
        if (!found) {
            print "[daemon]"
            print "AutomaticLoginEnable=true"
            print "AutomaticLogin=root"
            print "TimedLoginEnable=false"
        }
    }
' "$config" > "$config.library-new"
cat "$config.library-new" > "$config"
rm "$config.library-new"
# GDM starts the root desktop automatically on first boot.
