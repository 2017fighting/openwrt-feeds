'use strict';
'require poll';
'require rpc';
'require ui';
'require view';

const callCfstStatus = rpc.declare({
	object: 'luci.mosdns',
	method: 'get_cfst_status',
	expect: { '': {} }
});

const callReprobe = rpc.declare({
	object: 'luci.mosdns',
	method: 'reprobe',
	expect: { '': {} }
});

function esc(s) {
	return String(s == null ? '' : s).replace(/[&<>"]/g, c => ({
		'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
	}[c]));
}

function formatAge(refreshed_at) {
	if (!refreshed_at) return _('never');
	const t = Date.parse(refreshed_at);
	if (isNaN(t)) return esc(refreshed_at);
	let secs = Math.floor((Date.now() - t) / 1000);
	if (secs < 0) return _('just now');
	if (secs < 60) return _('%d s ago').format(secs);
	if (secs < 3600) return _('%d m ago').format(Math.floor(secs / 60));
	if (secs < 86400) return _('%d h ago').format(Math.floor(secs / 3600));
	return _('%d d ago').format(Math.floor(secs / 86400));
}

function ipList(label, ips) {
	if (!ips || !ips.length) return '';
	const items = ips.map(esc).join('<br>');
	return '<tr><th style="width:30%">' + label + '</th><td>' + items + '</td></tr>';
}

function statusHTML(res) {
	if (res.error) {
		return '<p style="color:red">' + _('Error: %s').format(esc(res.error)) + '</p>';
	}

	const params = res.params || {};
	const cache = res.cache;
	const interval = params.refresh_interval ? (esc(params.refresh_interval) + ' s') : _('default (21600 s)');

	let html = '<table class="table">';
	html += '<tr><th style="width:30%">' + _('Cache file') + '</th><td>' + esc(res.cache_file) + '</td></tr>';
	html += '<tr><th>' + _('Last refresh') + '</th><td>';
	html += (cache && cache.refreshed_at)
		? esc(cache.refreshed_at) + ' (' + formatAge(cache.refreshed_at) + ')'
		: _('no cache yet — run a probe');
	html += '</td></tr>';
	html += '<tr><th>' + _('Download URL') + '</th><td>' + esc(params.download_url || '-') + '</td></tr>';
	html += '<tr><th>' + _('Probe port') + '</th><td>' + esc(params.port || '-') + '</td></tr>';
	html += '<tr><th>' + _('Top-N retained') + '</th><td>' + esc(params.top_n || '-') + '</td></tr>';
	html += '<tr><th>' + _('Refresh interval') + '</th><td>' + interval + '</td></tr>';
	html += '<tr><th>' + _('Sample mode') + '</th><td>' + esc(params.sample_mode || 'random') + '</td></tr>';

	if (cache && ((cache.ipv4 && cache.ipv4.length) || (cache.ipv6 && cache.ipv6.length))) {
		html += '<tr><th colspan="2" style="text-align:center"><strong>' + _('Optimized IPs') + '</strong></th></tr>';
		html += ipList(_('IPv4'), cache.ipv4);
		html += ipList(_('IPv6'), cache.ipv6);
	}
	html += '</table>';
	return html;
}

return view.extend({
	load() {
		return L.resolveDefault(callCfstStatus(), {});
	},

	render(data) {
		const panel = E('div', { 'class': 'cbi-section', 'id': 'cfst_panel' });
		panel.innerHTML = statusHTML(data);

		const button = E('input', {
			'class': 'btn cbi-button-action',
			'type': 'button',
			'style': 'margin:10px',
			'value': _('Re-probe now')
		});
		button.addEventListener('click', () => {
			button.disabled = true;
			const original = button.value;
			button.value = _('Probing...');
			callReprobe().then(r => {
				if (!r.success) {
					ui.addNotification(null, E('p', _('Re-probe failed: %s').format(r.error || r.output || '')), 'error');
				} else {
					ui.addNotification(null, E('p', _('Re-probe triggered. The cache refreshes when the scan completes.')), 'info');
				}
			}).catch(e => ui.addNotification(null, E('p', e.message), 'error')).finally(() => {
				setTimeout(() => { button.disabled = false; button.value = original; }, 5000);
			});
		});

		poll.add(() => {
			return L.resolveDefault(callCfstStatus()).then(res => {
				panel.innerHTML = statusHTML(res);
			});
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'name': 'content' }, '%s - %s'.format(_('MosDNS'), _('Cloudflare Speedtest'))),
			E('div', { 'class': 'cbi-section' }, [
				button,
				panel,
				E('div', { 'style': 'text-align:right' },
					E('small', {}, _('Status refreshes automatically. Re-probe sends SIGUSR1 to mosdns.'))
				)
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
