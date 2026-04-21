Name:           winbind-watchdog
Version:        1.0.1
Release:        1%{?dist}
Summary:        Detect and recover hung winbind idmap/trust state
License:        GPL-3.0
URL:            https://github.com/NerdyGriffin/winbind-watchdog

Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
Requires:       samba-winbind
Requires:       krb5-workstation
Requires:       systemd
BuildRequires:  systemd
%{?systemd_requires}

%description
A systemd timer that periodically probes winbind with `wbinfo -t`. If the
probe fails (a classic symptom of winbindd getting wedged on idmap_ad or
trust credential operations, often after DC maintenance or machine password
rotation), the watchdog force-kills winbindd, refreshes the machine-account
Kerberos ticket via `kinit -k`, and restarts the winbind service.

Config lives in /etc/winbind-watchdog.conf.

%prep
%setup -q

%build
# Nothing to build — pure shell script package

%install
install -D -m 0755 winbind-watchdog.sh         %{buildroot}%{_sbindir}/winbind-watchdog.sh
install -D -m 0644 winbind-watchdog.service    %{buildroot}%{_unitdir}/winbind-watchdog.service
install -D -m 0644 winbind-watchdog.timer      %{buildroot}%{_unitdir}/winbind-watchdog.timer
install -D -m 0644 winbind-watchdog.logrotate  %{buildroot}%{_sysconfdir}/logrotate.d/winbind-watchdog
install -D -m 0644 winbind-watchdog.conf.example %{buildroot}%{_sysconfdir}/winbind-watchdog.conf

%files
%{_sbindir}/winbind-watchdog.sh
%{_unitdir}/winbind-watchdog.service
%{_unitdir}/winbind-watchdog.timer
%{_sysconfdir}/logrotate.d/winbind-watchdog
%config(noreplace) %{_sysconfdir}/winbind-watchdog.conf

%post
systemctl daemon-reload &>/dev/null || :
if [ $1 -eq 1 ] ; then
    # Initial installation — enable and start the timer (not the service unit)
    systemctl enable --now winbind-watchdog.timer &>/dev/null || :
fi

%preun
%systemd_preun winbind-watchdog.timer winbind-watchdog.service

%postun
systemctl daemon-reload &>/dev/null || :

%changelog
* Tue Apr 21 2026 NerdyGriffin - 1.0.1-1
- Remove ConditionPathIsExecutable= from .service unit (not supported on
  EL8's systemd 239)

* Tue Apr 21 2026 NerdyGriffin - 1.0.0-1
- Initial RPM package
- Probe: `wbinfo -t` with configurable timeout
- Recovery: pkill -9 winbindd + kinit -k + systemctl restart winbind
