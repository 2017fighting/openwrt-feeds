'use strict';
'require form';
'require fs';
'require ui';
'require view';

// Track whether any rule file changed during a save, so we restart mosdns once
// (only when needed) instead of once per file.
let rulesDirty = false;

function ruleEditor(s, tabId, optId, title, hint, path) {
	s.tab(tabId, title);

	const o = s.taboption(tabId, form.TextValue, optId, null,
		'<font color="red">' + hint + '</font>');
	o.rows = 25;
	o.cfgvalue = section_id => fs.trimmed(path).catch(() => '');
	o.write = function(section_id, formvalue) {
		return this.cfgvalue(section_id).then(value => {
			if (value === formvalue) {
				return;
			}
			const content = formvalue.trim() ? formvalue.trim().replace(/\r\n/g, '\n') + '\n' : '';
			return fs.write(path, content).then(() => { rulesDirty = true; });
		});
	};
	o.remove = section_id => fs.write(path, '').catch(e => {
		ui.addNotification(null, E('p', _('Unable to save contents: %s').format(e.message)));
	});
}

return view.extend({
	render() {
		let m, s;

		m = new form.Map('mosdns', _('Rule Settings'),
			_('List files referenced by /etc/mosdns/config.yaml. Save &amp; Apply writes the files and restarts mosdns.'));

		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.sortable = true;

		ruleEditor(s, 'whitelist', '_whitelist', _('White Lists'),
			_('Domains here are always forwarded to upstream with the highest priority (one domain per line).'),
			'/etc/mosdns/rule/whitelist.txt');

		ruleEditor(s, 'hosts', '_hosts', _('Hosts'),
			_('Custom hosts rewrite, e.g. example.com 10.0.0.1 (one rule per line).'),
			'/etc/mosdns/rule/hosts.txt');

		ruleEditor(s, 'cloudflarecidr', '_cloudflarecidr', _('Cloudflare CIDR'),
			_('Cloudflare CIDR ranges whose response IPs trigger cfst_pool/lpush (one CIDR per line).'),
			'/etc/mosdns/rule/cloudflare-cidr.txt');

		return m.render();
	},

	handleSaveApply(ev) {
		return this.handleSave(ev).then(() => {
			if (!rulesDirty) return;
			return fs.exec('/etc/init.d/mosdns', ['restart']);
		}).then(() => {
			rulesDirty = false;
			window.location.reload();
		}).catch(e => {
			rulesDirty = false;
			ui.addNotification(null, E('p', _('Unable to apply: %s').format(e.message)));
		});
	},

	handleReset: null
});
