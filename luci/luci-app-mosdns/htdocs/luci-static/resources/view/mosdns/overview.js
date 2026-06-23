'use strict';
'require form';
'require fs';
'require poll';
'require rpc';
'require ui';
'require view';

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

function getServiceStatus() {
	return L.resolveDefault(callServiceList('mosdns'), {}).then(res => {
		let isRunning = false;
		try {
			isRunning = res['mosdns']['instances']['mosdns']['running'];
		} catch (e) { }
		return isRunning;
	});
}

function renderStatus(isRunning) {
	const spanTemp = '<em><span style="color:%s"><strong>%s %s</strong></span></em>';
	if (isRunning) {
		return spanTemp.format('green', _('MosDNS'), _('RUNNING'));
	}
	return spanTemp.format('red', _('MosDNS'), _('NOT RUNNING'));
}

// Minimal CodeMirror set: core + yaml mode + lint (catches broken YAML before save).
async function loadCodeMirrorResources() {
	const styles = [
		'/luci-static/resources/codemirror5/addon/lint/lint.min.css',
		'/luci-static/resources/codemirror5/codemirror.min.css',
	];
	const scripts = [
		'/luci-static/resources/codemirror5/libs/js-yaml.min.js',
		'/luci-static/resources/codemirror5/codemirror.min.js',
		'/luci-static/resources/codemirror5/addon/display/autorefresh.min.js',
		'/luci-static/resources/codemirror5/mode/yaml/yaml.min.js',
		'/luci-static/resources/codemirror5/addon/lint/lint.min.js',
		'/luci-static/resources/codemirror5/addon/lint/yaml-lint.min.js',
	];
	for (const href of styles) {
		const link = document.createElement('link');
		link.rel = 'stylesheet';
		link.href = href;
		document.head.appendChild(link);
	}
	for (const src of scripts) {
		const script = document.createElement('script');
		script.src = src;
		document.head.appendChild(script);
		await new Promise(resolve => script.onload = resolve);
	}
}

return view.extend({
	render() {
		let m, s, o;

		m = new form.Map('mosdns', _('MosDNS'),
			_('mosdns with in-process CloudflareSpeedTest (cfst_pool + lpush). Edit /etc/mosdns/config_custom.yaml directly below; Save writes the file and restarts mosdns.'));

		// Service status banner.
		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.render = () => {
			setTimeout(() => {
				poll.add(() => {
					return L.resolveDefault(getServiceStatus()).then(res => {
						const view = document.getElementById('service_status');
						if (view) view.innerHTML = renderStatus(res);
					});
				});
			}, 100);
			loadCodeMirrorResources();
			return E('div', { class: 'cbi-section', id: 'status_bar' }, [
				E('p', { id: 'service_status' }, _('Collecting data...'))
			]);
		};

		// UCI options: enabled / configfile / redirect.
		s = m.section(form.NamedSection, 'config', 'mosdns');

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.rmempty = false;
		o.default = o.disabled;

		o = s.option(form.Value, 'configfile', _('Config File'));
		o.default = '/etc/mosdns/config_custom.yaml';
		o.rmempty = false;

		o = s.option(form.Flag, 'redirect', _('DNS Forward'),
			_('Forward Dnsmasq DNS requests to MosDNS (parses the listen port from the YAML).'));
		o.rmempty = false;
		o.default = o.disabled;

		// YAML editor — config_custom.yaml is the source of truth.
		let configeditor = null;
		setTimeout(() => {
			const textarea = document.getElementById('widget.cbid.mosdns.config._custom');
			if (textarea) {
				configeditor = CodeMirror.fromTextArea(textarea, {
					autoRefresh: true,
					lineNumbers: true,
					lineWrapping: true,
					lint: true,
					gutters: ['CodeMirror-lint-markers'],
					matchBrackets: true,
					mode: 'text/yaml',
					styleActiveLine: true
				});
			}
		}, 600);

		o = s.option(form.TextValue, '_custom', _('Configuration Editor'),
			_('Direct edit of the mosdns pipeline. Save writes the file and restarts mosdns.'));
		o.rows = 25;
		o.cfgvalue = section_id => fs.trimmed('/etc/mosdns/config_custom.yaml');
		o.write = function(section_id, formvalue) {
			if (configeditor) {
				const editorContent = configeditor.getValue();
				if (editorContent === formvalue) {
					return;
				}
				return fs.write('/etc/mosdns/config_custom.yaml', editorContent.trim().replace(/\r\n/g, '\n') + '\n')
					.then(() => fs.exec('/etc/init.d/mosdns', ['restart']))
					.then(() => window.location.reload())
					.catch(e => {
						ui.addNotification(null, E('p', _('Unable to save contents: %s').format(e.message)));
					});
			}
		};

		return m.render();
	}
});
