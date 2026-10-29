'use strict';
'require view';
'require rpc';
'require ui';

// One page for the three things this image does differently from stock
// OpenWrt. Two of them interact: the TTL rewrite and the NSS fast path are
// mutually exclusive, because ECM bypasses netfilter and offloaded flows keep
// their original TTL. The page makes that relationship visible rather than
// leaving the user to discover it.

var callStatus = rpc.declare({ object: 'custom', method: 'status', expect: { status: {} } });
var callTtl    = rpc.declare({ object: 'custom', method: 'ttl_apply', params: [ 'enable', 'ttl4', 'hl6', 'meta_mode' ] });
var callNss    = rpc.declare({ object: 'custom', method: 'nss_set', params: [ 'state' ] });
var callAghIn  = rpc.declare({ object: 'custom', method: 'agh_install' });
var callAghRev = rpc.declare({ object: 'custom', method: 'agh_revert' });

var CSS = [
	'.ct-wrap{max-width:940px}',
	'.ct-hero{display:flex;align-items:center;gap:14px;padding:16px 20px;margin:0 0 18px;',
	'border-radius:10px;background:linear-gradient(135deg,#0b3a4a 0%,#0e5568 100%);color:#eaf7fb}',
	'.ct-hero b{font-size:1.28em;letter-spacing:.02em}',
	'.ct-hero small{opacity:.82;display:block;margin-top:3px}',
	'.ct-mark{width:44px;height:44px;flex:0 0 auto;border-radius:9px;background:#00b5e2;',
	'display:flex;align-items:center;justify-content:center;font-weight:800;font-size:24px;color:#04303d}',
	'.ct-card{border:1px solid rgba(128,128,128,.28);border-radius:10px;margin:0 0 16px;',
	'overflow:hidden;background:rgba(128,128,128,.04)}',
	'.ct-card>.ct-head{display:flex;align-items:center;gap:10px;padding:12px 16px;',
	'border-bottom:1px solid rgba(128,128,128,.22);font-weight:600;font-size:1.02em}',
	'.ct-card>.ct-head .ct-sp{flex:1 1 auto}',
	'.ct-body{padding:14px 16px}',
	'.ct-body p.ct-desc{margin:0 0 14px;opacity:.85;line-height:1.5}',
	'.ct-row{display:flex;align-items:center;gap:12px;padding:7px 0;flex-wrap:wrap}',
	'.ct-row>label{min-width:170px;opacity:.9}',
	'.ct-pill{display:inline-block;padding:2px 10px;border-radius:11px;font-size:84%;',
	'font-weight:600;color:#fff;letter-spacing:.02em}',
	'.ct-on{background:#2e7d32}.ct-off{background:#6b6b6b}.ct-warn{background:#b26a00}',
	'.ct-off2{background:#8e2f2f}',
	'.ct-note{margin:12px 0 0;padding:10px 12px;border-radius:7px;font-size:92%;',
	'border-left:3px solid #00b5e2;background:rgba(0,181,226,.10);line-height:1.5}',
	'.ct-note.warn{border-left-color:#b26a00;background:rgba(178,106,0,.12)}',
	'.ct-actions{display:flex;gap:9px;flex-wrap:wrap;margin-top:14px}',
	'.ct-in{width:6.2em;padding:4px 7px;border-radius:5px;border:1px solid rgba(128,128,128,.45);',
	'background:transparent;color:inherit}',
	'.ct-sel{padding:4px 7px;border-radius:5px;border:1px solid rgba(128,128,128,.45);',
	'background:transparent;color:inherit}',
	'.ct-out{white-space:pre-wrap;max-height:20em;overflow:auto;margin:0;padding:11px 13px;',
	'border-radius:7px;background:#101418;color:#d6e3ea;font-size:88%;line-height:1.45}',
	'.ct-out:empty{display:none}'
].join('');

function pill(state, onText, offText) {
	var cls = state ? 'ct-on' : 'ct-off';
	return E('span', { 'class': 'ct-pill ' + cls }, [ state ? onText : offText ]);
}

return view.extend({
	load: function() {
		return callStatus();
	},

	render: function(res) {
		var s = (res && res.status) || {};
		var out = E('pre', { 'class': 'ct-out' });
		var self = this;

		/* ---------- helpers ---------- */
		function report(r) {
			var o = (r && r.result) || r || {};
			out.textContent = o.output || _('(no output)');
			ui.addNotification(null, E('p', {}, [
				o.ok ? _('Applied.') : _('Failed - see the output below.')
			]), o.ok ? 'info' : 'danger');
		}

		function busy(label, fn) {
			ui.showModal(label, [ E('p', { 'class': 'spinning' }, [ _('Working…') ]) ]);
			return fn().then(function(r) {
				ui.hideModal();
				report(r);
				/* Re-render so every pill reflects the new state. */
				return callStatus().then(function(st) {
					var host = document.getElementById('ct-root');
					if (host && st)
						host.replaceWith(self.render(st));
				});
			}).catch(function(e) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, [ _('Request failed: ') + e ]), 'danger');
			});
		}

		function card(title, badgeNode, bodyNodes) {
			return E('div', { 'class': 'ct-card' }, [
				E('div', { 'class': 'ct-head' }, [ title, E('span', { 'class': 'ct-sp' }), badgeNode ]),
				E('div', { 'class': 'ct-body' }, bodyNodes)
			]);
		}

		/* ---------- 1. TTL ---------- */
		var ttlOn = s.ttl_enabled == '1';
		var ttlEnable = E('input', { 'type': 'checkbox', 'checked': ttlOn });
		var ttl4 = E('input', { 'class': 'ct-in', 'type': 'number', 'value': s.ttl4 || 64,
			'min': 1, 'max': 255 });
		var hl6 = E('input', { 'class': 'ct-in', 'type': 'number', 'value': s.hl6 || 64,
			'min': 1, 'max': 255 });
		var mode = E('select', { 'class': 'ct-sel' },
			[ 'wwan_only', 'lan', 'global' ].map(function(m) {
				return E('option', { 'value': m, 'selected': (s.ttl_mode || 'wwan_only') == m }, [ m ]);
			}));

		var ttlCard = card(_('TTL / HopLimit rewrite'), pill(ttlOn, _('ON'), _('OFF')), [
			E('p', { 'class': 'ct-desc' }, [
				_('Rewrites TTL (IPv4) and HopLimit (IPv6) on traffic leaving through the modem, so ' +
				  'the carrier sees a fixed value. In '), E('code', {}, [ 'wwan_only' ]),
				_(' mode only the modem interfaces are touched - the correct hook. A rule keyed on ' +
				  'the LAN bridge also rewrites LAN-to-LAN traffic.')
			]),
			E('div', { 'class': 'ct-row' }, [
				E('label', {}, [ _('Enabled') ]), ttlEnable,
				E('span', { 'style': 'opacity:.7;font-size:90%' }, [
					_('(turn this off before enabling NSS offload)')
				])
			]),
			E('div', { 'class': 'ct-row' }, [
				E('label', {}, [ _('TTL (IPv4)') ]), ttl4,
				E('label', { 'style': 'min-width:auto' }, [ _('HopLimit (IPv6)') ]), hl6
			]),
			E('div', { 'class': 'ct-row' }, [ E('label', {}, [ _('Scope') ]), mode ]),
			E('div', { 'class': 'ct-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, function() {
						return busy(_('Applying TTL settings…'), function() {
							return callTtl(ttlEnable.checked ? '1' : '0',
								String(ttl4.value || 64), String(hl6.value || 64), mode.value);
						});
					})
				}, [ _('Apply') ])
			])
		]);

		/* ---------- 2. NSS offload ---------- */
		var ecmOn = s.ecm_loaded == '1';
		var nssCard = card(_('NSS / ECM flow offload'), pill(ecmOn, _('ON'), _('OFF')), [
			E('p', { 'class': 'ct-desc' }, [
				_('Offloads established flows to the NSS firmware. Faster, but '),
				E('b', {}, [ _('incompatible with the TTL rewrite above:') ]),
				_(' ECM bypasses netfilter entirely, so offloaded flows keep their original TTL.')
			]),
			ttlOn && !ecmOn
				? E('p', { 'class': 'ct-note warn' }, [
					_('TTL rewriting is currently ON. Turning NSS offload on will let offloaded ' +
					  'flows escape the rewrite. Turn TTL off first if that matters to you.')
				  ])
				: E('p', { 'class': 'ct-note' }, [
					_('TTL rewriting is off, so offload can be enabled without conflict.')
				  ]),
			s.nss_available == '1'
				? E('div', { 'class': 'ct-actions' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(this, function() {
							if (!confirm(_('Enable NSS offload? The TTL rewrite will not apply to offloaded flows.')))
								return;
							return busy(_('Enabling NSS offload…'), function() { return callNss('1'); });
						})
					}, [ _('Turn ON') ]),
					E('button', {
						'class': 'btn cbi-button cbi-button-reset',
						'click': ui.createHandlerFn(this, function() {
							return busy(_('Disabling NSS offload…'), function() { return callNss('0'); });
						})
					}, [ _('Turn OFF') ])
				])
				: E('p', { 'class': 'ct-note warn' }, [ _('qca-nss-ecm is not installed in this image.') ])
		]);

		/* ---------- 3. AdGuard Home + PassWall2 ---------- */
		var aghOn = s.agh_enabled == '1';
		var aghCard = card(_('AdGuard Home + PassWall2'), pill(aghOn, _('ON'), _('OFF')), [
			E('p', { 'class': 'ct-desc' }, [
				_('Both want to own DNS. Left alone they fight over port 53 and you get "problem ' +
				  'detected" from PassWall, or google.com resolving to forcesafesearch. This wires ' +
				  'the chain:')
			]),
			E('pre', {
				'style': 'margin:0 0 14px;padding:10px 12px;border-radius:7px;' +
					'background:rgba(128,128,128,.10);font-size:88%;line-height:1.5;overflow:auto'
			}, [ 'LAN clients → :53  AdGuard Home (filtering)\n' +
			     '              └→ 127.0.0.1:15353  PassWall2 (split DNS)\n' +
			     '              └→ .lan/.local/.home.arpa → 127.0.0.1:54  dnsmasq' ]),
			E('div', { 'class': 'ct-row' }, [
				E('label', {}, [ _('AdGuard Home') ]),
				pill(s.agh_installed == '1', _('installed'), _('not installed')),
				pill(s.agh_luci_installed == '1', _('LuCI app'), _('no LuCI app'))
			]),
			E('div', { 'class': 'ct-row' }, [
				E('label', {}, [ _('dnsmasq port') ]),
				E('b', {}, [ String(s.dnsmasq_port || 53) ]),
				pill(s.passwall_redirect != '1', _('PassWall DNS redirect off'), _('PassWall still hijacks :53'))
			]),
			E('p', { 'class': 'ct-note' }, [
				_('Neither AdGuard package is in the image - the installer pulls them from the feed ' +
				  'on first run. No proxy nodes are added; do that in Services → PassWall2.')
			]),
			E('div', { 'class': 'ct-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, function() {
						return busy(_('Configuring AdGuard Home + PassWall2…'), callAghIn);
					})
				}, [ _('Install / reconfigure') ]),
				E('button', {
					'class': 'btn cbi-button cbi-button-reset',
					'click': ui.createHandlerFn(this, function() {
						if (!confirm(_('Put dnsmasq back on port 53 and stop AdGuard Home?')))
							return;
						return busy(_('Reverting…'), callAghRev);
					})
				}, [ _('Revert DNS changes') ])
			]),
			E('p', { 'class': 'ct-desc', 'style': 'margin:14px 0 0' }, [
				_('After a first install, open '),
				E('a', { 'href': 'http://' + window.location.hostname + ':3000', 'target': '_blank' },
					[ window.location.hostname + ':3000' ]),
				_(' to create the AdGuard Home admin account.')
			])
		]);

		/* ---------- assemble ---------- */
		var root = E('div', { 'class': 'ct-wrap', 'id': 'ct-root' }, [
			E('style', {}, [ CSS ]),
			E('div', { 'class': 'ct-hero' }, [
				E('div', { 'class': 'ct-mark' }, [ 'B' ]),
				E('div', {}, [
					E('b', {}, [ 'AW1000_NSS_BYTE' ]),
					E('small', {}, [ _('Image-specific switches · Arcadyan AW1000 · NSS EDMA') ])
				])
			]),
			ttlCard,
			nssCard,
			aghCard,
			E('div', { 'class': 'ct-card' }, [
				E('div', { 'class': 'ct-head' }, [ _('Output') ]),
				E('div', { 'class': 'ct-body' }, [ out ])
			])
		]);

		return root;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
