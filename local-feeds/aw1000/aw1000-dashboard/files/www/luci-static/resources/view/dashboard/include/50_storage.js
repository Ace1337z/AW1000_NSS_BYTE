'use strict';
'require baseclass';
'require rpc';
'require view.dashboard.lib.charts as charts';
// Storage card. Reads /overlay (the writable root) through ubus system.info,
// which the dashboard's ACL already grants. /overlay is where everything this
// image writes at runtime lives: UCI config, installed packages, the vnstat
// database. The NSS-offload card this replaces could never show anything -
// ppe-nss ships no qca-nss-ecm, so its counter file stayed empty.
var callSystemInfo = rpc.declare({
	object: 'system',
	method: 'info',
	expect: { root: {} }
});
function human(kb) {
	var n = kb * 1024, units = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ], i = 0;
	while (n >= 1024 && i < units.length - 1) {
		n /= 1024;
		i++;
	}
	return '%.1f %s'.format(n, units[i]);
}
return baseclass.extend({
	widgets: [
		{ id: 'storage', slot: 'cards', title: _('Storage'), order: 25 }
	],
	available() {
		return true;
	},
	load() {
		return L.resolveDefault(callSystemInfo(), null);
	},
	render(root) {
		// expect:{root:{}} already unwraps the ubus reply to the object inside
		// "root"; dereferencing root.root here would always miss and show
		// "unavailable".
		root = L.isObject(root) ? root : {};
		var total = (root.total != null) ? +root.total : null,
		    used = (root.used != null) ? +root.used : null,
		    free = (total != null && used != null) ? total - used : null,
		    pct = (total > 0 && used != null) ? Math.round(used * 100 / total) : null;
		return {
			cards: [ {
				id: 'storage',
				node: () => charts.kpi({
					icon: 'storage',
					title: _('Storage'),
					value: [ (pct != null) ? String(pct) + '%' : '-' ],
					sub: (pct != null) ? [
						_('%s of %s used').format(human(used), human(total)),
						_('%s free').format(human(free))
					] : [ _('unavailable') ]
				})
			} ]
		};
	}
});
