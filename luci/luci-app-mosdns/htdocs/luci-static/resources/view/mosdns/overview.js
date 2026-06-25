'use strict';
'require form';
'require fs';
'require poll';
'require rpc';
'require uci';
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
	load() {
		// Resolve the active config file once from UCI (mosdns.config.configfile)
		// so the editor below follows whatever the "Config File" field is set to,
		// instead of always reading/writing config_custom.yaml.
		return uci.load('mosdns').then(() => {
			this.configPath = uci.get('mosdns', 'config', 'configfile')
				|| '/etc/mosdns/config_custom.yaml';
		});
	},

	render() {
		const configPath = this.configPath || '/etc/mosdns/config_custom.yaml';
		let m, s, o;

		m = new form.Map('mosdns', _('MosDNS'),
			_('mosdns with in-process CloudflareSpeedTest (cfst_pool + lpush). The editor below edits the file selected in "Config File"; Save writes it and restarts mosdns.'));

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

		// YAML editor — edits the file named by the "Config File" field (configPath).
		let configeditor = null;

		// CodeMirror's default theme hardcodes a white background + black text,
		// which clashes with the active LuCI theme (badly on dark themes, and
		// looks unstyled on light ones). Probe the theme's own textarea styling
		// and mirror it onto the editor so it always blends in.
		function adaptCodeMirrorTheme(cm) {
			const probe = document.createElement('textarea');
			probe.className = 'cbi-input-textarea';
			probe.style.cssText = 'position:absolute;visibility:hidden;';
			document.body.appendChild(probe);
			const s = getComputedStyle(probe);
			const bg = s.backgroundColor, fg = s.color, bd = s.borderColor;
			probe.remove();

			const rules = [
				(bg && bg !== 'rgba(0, 0, 0, 0)') ? `.cbi-map .CodeMirror, .cbi-map .CodeMirror-scroll, .cbi-map .CodeMirror-gutters { background-color: ${bg} !important; }` : null,
				fg ? `.cbi-map .CodeMirror { color: ${fg} !important; }` : null,
				fg ? `.cbi-map .CodeMirror-linenumber { color: ${fg} !important; opacity: .5; }` : null,
				fg ? `.cbi-map .CodeMirror-cursor { border-left-color: ${fg} !important; }` : null,
				`.cbi-map .CodeMirror-activeline-background { background: rgba(127,127,127,.15) !important; }`,
				bd ? `.cbi-map .CodeMirror { border: 1px solid ${bd} !important; }` : null
			].filter(Boolean);
			const style = document.createElement('style');
			style.textContent = rules.join('\n');
			document.head.appendChild(style);
		}

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
				adaptCodeMirrorTheme(configeditor);
			}
		}, 600);

		o = s.option(form.TextValue, '_custom', _('Configuration Editor'),
			_('Edits the file selected in "Config File". Save writes it and restarts mosdns.'));
		o.rows = 25;
		o.cfgvalue = section_id => fs.trimmed(configPath).catch(() => '');

		o.write = function(section_id, formvalue) {
			if (!configeditor)
				return;

			const editorContent = configeditor.getValue();
			if (editorContent === formvalue)
				return;

			// Follow the "Config File" field: read its live value from the DOM so
			// changing the path and saving in one pass writes to the newly selected
			// file, falling back to the UCI value resolved at load time.
			const input = document.getElementById('widget.cbid.mosdns.config.configfile');
			const target = (input && input.value && input.value.trim()) || configPath;

			return fs.write(target, editorContent.trim().replace(/\r\n/g, '\n') + '\n')
				.then(() => fs.exec('/etc/init.d/mosdns', ['restart']))
				.then(() => window.location.reload())
				.catch(e => {
					ui.addNotification(null, E('p', _('Unable to save contents: %s').format(e.message)));
				});
		};

		return m.render();
	}
});
