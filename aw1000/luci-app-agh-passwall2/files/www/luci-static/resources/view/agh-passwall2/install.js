'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require poll';

// One-click installer for Ace1337z's AdGuard Home + PassWall2 DNS chain.
//
// AdGuard Home and PassWall2 both want to own DNS. Left alone they fight over
// port 53 and the user sees "problem detected" from PassWall's DNS hijack
// check, or google.com silently resolving to forcesafesearch. The upstream
// project solves it with a shell script; this page is a button for that script
// plus a status readout, so it can be done from LuCI instead of SSH.

var callStatus  = rpc.declare({ object: 'agh-passwall2', method: 'status',  expect: { status: {} } });
var callInstall = rpc.declare({ object: 'agh-passwall2', method: 'install', expect: { } });
var callRevert  = rpc.declare({ object: 'agh-passwall2', method: 'revert',  expect: { } });

function badge(ok, yes, no) {
	return E('span', {
		'style': 'display:inline-block;padding:1px 8px;border-radius:9px;font-size:90%;' +
			'background:' + (ok ? '#2e7d32' : '#9e9e9e') + ';color:#fff'
	}, [ ok ? yes : no ]);
}

return view.extend({
	load: function() {
		return callStatus();
	},

	render: function(status) {
		var s = (status && status.status) || {};
		var out = E('div', { 'id': 'agh-pw-output' });

		/* ---- status ---- */
		var rows = [
			[ _('AdGuard Home core'),      badge(s.agh_installed,       _('installed'), _('not installed')) ],
			[ _('AdGuard Home LuCI app'),  badge(s.agh_luci_installed,  _('installed'), _('not installed')) ],
			[ _('PassWall2'),              badge(s.passwall_installed,  _('installed'), _('not installed')) ],
			[ _('AdGuard Home service'),   badge(s.agh_enabled == '1',  _('enabled'),   _('disabled')) ],
			[ _('dnsmasq port'),           E('b', {}, [ String(s.dnsmasq_port || 53) ]) ],
			[ _('Port 53 in use'),         badge(s.port53_in_use,       _('yes'),       _('no')) ],
			[ _('PassWall2 DNS redirect'), badge(s.passwall_dns_redirect != '1', _('off (correct)'), _('on (will fight AdGuard)')) ]
		];

		var table = E('table', { 'class': 'table' }, rows.map(function(r) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'style': 'width:45%' }, [ r[0] ]),
				E('td', { 'class': 'td left' }, [ r[1] ])
			]);
		}));

		/* ---- actions ---- */
		function run(fn, label) {
			ui.showModal(label, [ E('p', { 'class': 'spinning' }, [ _('Working…') ]) ]);
			return fn().then(function(res) {
				var r = (res && res.result) || res || {};
				ui.hideModal();
				out.innerHTML = '';
				out.appendChild(E('pre', {
					'style': 'white-space:pre-wrap;max-height:26em;overflow:auto;' +
						'background:#111;color:#ddd;padding:10px;border-radius:6px;font-size:90%'
				}, [ r.output || _('(no output)') ]));
				ui.addNotification(null, E('p', {}, [
					r.ok ? _('Done. Reload the page to see the new state.')
					     : _('Finished with errors — see the output below.')
				]), r.ok ? 'info' : 'warning');
				return callStatus().then(function(st) {
					var n = (st && st.status) || {};
					/* cheap in-place refresh of the badges */
					location.reload();
					return n;
				});
			}).catch(function(e) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, [ _('Request failed: ') + e ]), 'error');
			});
		}

		var btnInstall = E('button', {
			'class': 'btn cbi-button cbi-button-apply',
			'click': ui.createHandlerFn(this, function() {
				return run(callInstall, _('Configuring AdGuard Home + PassWall2…'));
			})
		}, [ _('Install / reconfigure') ]);

		var btnRevert = E('button', {
			'class': 'btn cbi-button cbi-button-reset',
			'click': ui.createHandlerFn(this, function() {
				if (!confirm(_('Put dnsmasq back on port 53 and stop AdGuard Home?')))
					return;
				return run(callRevert, _('Reverting…'));
			})
		}, [ _('Revert DNS changes') ]);

		return E('div', {}, [
			E('h2', {}, [ _('AdGuard Home + PassWall2') ]),
			E('p', { 'class': 'cbi-section-descr' }, [
				_('One-click setup of the DNS chain: LAN clients ask AdGuard Home on :53, ' +
				  'AdGuard forwards to PassWall2 on 127.0.0.1:15353, and .lan/.local/.home.arpa ' +
				  'go back to dnsmasq on :54. SafeSearch/parental filtering is turned off. ' +
				  'No proxy nodes are added — do that in Services → PassWall2.')
			]),
			E('p', { 'class': 'cbi-section-descr' }, [
				_('Both packages are installed on demand; they are not part of the firmware image. ' +
				  'This page runs the vendored installer from ') ,
				E('code', {}, [ 'github.com/Ace1337z/openwrt-agh-passwall2' ]), '.'
			]),
			E('h3', {}, [ _('Current state') ]),
			table,
			E('div', { 'class': 'cbi-page-actions' }, [
				btnInstall, ' ', btnRevert
			]),
			E('h3', {}, [ _('Output') ]),
			out,
			E('p', { 'class': 'cbi-section-descr' }, [
				_('After a first install, open ') ,
				E('a', { 'href': 'http://' + window.location.hostname + ':3000', 'target': '_blank' },
					[ 'http://' + window.location.hostname + ':3000' ]),
				_(' to create the AdGuard Home admin account.')
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
