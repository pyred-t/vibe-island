/**
 * Claude Island Windows — Code Preview Module
 * Scrollable, structured tool-input preview for permission requests
 */

const CodePreview = (() => {

  /**
   * Build a rich permission preview element for a session's activePermission.
   * @param {object} permission  - { toolName, toolInput, toolUseId }
   * @returns {HTMLElement}
   */
  function buildPermissionPreview(permission) {
    const { toolName } = permission;
    let { toolInput } = permission;
    // tool_input may arrive as a JSON string — parse it
    if (typeof toolInput === 'string') {
      try { toolInput = JSON.parse(toolInput); } catch (e) { toolInput = {}; }
    }
    const wrapper = document.createElement('div');
    wrapper.className = 'perm-preview';

    // Tool name header
    const header = document.createElement('div');
    header.className = 'perm-preview-header';
    header.innerHTML = `<span class="perm-tool-name">${_esc(toolName)}</span>`;
    wrapper.appendChild(header);

    // Structured content based on tool type
    const content = _buildContent(toolName, toolInput || {});
    wrapper.appendChild(content);

    return wrapper;
  }

  function _buildContent(toolName, input) {
    switch (toolName) {
      case 'Bash':
      case 'computer':
        return _bashPreview(input);
      case 'Write':
      case 'Edit':
      case 'MultiEdit':
        return _fileEditPreview(toolName, input);
      case 'Read':
        return _readPreview(input);
      case 'WebFetch':
      case 'WebSearch':
        return _webPreview(toolName, input);
      default:
        return _genericJsonPreview(input);
    }
  }

  // ─── Bash preview ─────────────────────────────────────────────
  function _bashPreview(input) {
    const cmd = input.command || input.cmd || '';
    const desc = input.description || input.justification || '';

    const el = document.createElement('div');
    el.className = 'perm-content';

    if (desc) {
      const descEl = document.createElement('div');
      descEl.className = 'perm-description';
      descEl.innerHTML = typeof MarkdownLite !== 'undefined' ? MarkdownLite.render(desc) : _esc(desc);
      el.appendChild(descEl);
    }

    if (cmd) {
      const pre = _codeBlock(cmd, 'bash');
      el.appendChild(pre);
    } else if (Object.keys(input).length > 0) {
      el.appendChild(_genericJsonPreview(input));
    }

    return el;
  }

  // ─── File edit preview ────────────────────────────────────────
  function _fileEditPreview(toolName, input) {
    const el = document.createElement('div');
    el.className = 'perm-content';

    const filePath = input.file_path || input.path || '';
    if (filePath) {
      const pathEl = document.createElement('div');
      pathEl.className = 'perm-filepath';
      pathEl.innerHTML = `<span class="perm-filepath-icon">📄</span><span>${_esc(filePath)}</span>`;
      el.appendChild(pathEl);
    }

    if (toolName === 'Edit' || toolName === 'MultiEdit') {
      const oldStr = input.old_string || '';
      const newStr = input.new_string || '';
      if (oldStr || newStr) {
        el.appendChild(_diffPreview(oldStr, newStr));
        return el;
      }
    }

    if (toolName === 'Write' && input.content) {
      const preview = input.content.slice(0, 400);
      el.appendChild(_codeBlock(preview + (input.content.length > 400 ? '\n…' : ''), ''));
    }

    return el;
  }

  // ─── Read preview ─────────────────────────────────────────────
  function _readPreview(input) {
    const el = document.createElement('div');
    el.className = 'perm-content';

    const filePath = input.file_path || input.path || '';
    if (filePath) {
      const pathEl = document.createElement('div');
      pathEl.className = 'perm-filepath';
      pathEl.innerHTML = `<span class="perm-filepath-icon">📖</span><span>${_esc(filePath)}</span>`;
      el.appendChild(pathEl);
    }

    if (input.offset || input.limit) {
      const meta = document.createElement('div');
      meta.className = 'perm-meta';
      const parts = [];
      if (input.offset) parts.push(`offset: ${input.offset}`);
      if (input.limit)  parts.push(`limit: ${input.limit}`);
      meta.textContent = parts.join(', ');
      el.appendChild(meta);
    }

    return el;
  }

  // ─── Web preview ──────────────────────────────────────────────
  function _webPreview(toolName, input) {
    const el = document.createElement('div');
    el.className = 'perm-content';

    const url = input.url || input.query || '';
    if (url) {
      const urlEl = document.createElement('div');
      urlEl.className = 'perm-filepath';
      urlEl.innerHTML = `<span class="perm-filepath-icon">${toolName === 'WebSearch' ? '🔍' : '🌐'}</span><span class="perm-url">${_esc(url)}</span>`;
      el.appendChild(urlEl);
    }

    return el;
  }

  // ─── Generic JSON preview ─────────────────────────────────────
  function _genericJsonPreview(input) {
    const el = document.createElement('div');
    el.className = 'perm-content';

    if (!input || Object.keys(input).length === 0) return el;

    // Show key fields first, then rest as JSON
    const interesting = ['command', 'path', 'file_path', 'url', 'query', 'description', 'justification'];
    const shown = new Set();

    for (const key of interesting) {
      if (input[key]) {
        const row = document.createElement('div');
        row.className = 'perm-kv-row';
        row.innerHTML = `<span class="perm-kv-key">${_esc(key)}</span><span class="perm-kv-val">${_esc(String(input[key]).slice(0, 200))}</span>`;
        el.appendChild(row);
        shown.add(key);
      }
    }

    // Remaining keys as collapsible JSON
    const rest = {};
    for (const [k, v] of Object.entries(input)) {
      if (!shown.has(k)) rest[k] = v;
    }

    if (Object.keys(rest).length > 0) {
      const jsonStr = JSON.stringify(rest, null, 2);
      const block = _codeBlock(jsonStr.slice(0, 600) + (jsonStr.length > 600 ? '\n…' : ''), 'json');
      block.classList.add('perm-json-rest');

      if (shown.size > 0) {
        // Collapsible
        const toggle = document.createElement('button');
        toggle.className = 'perm-expand-btn';
        toggle.textContent = 'Show more ▾';
        toggle.addEventListener('click', () => {
          const expanded = block.style.display !== 'none';
          block.style.display = expanded ? 'none' : 'block';
          toggle.textContent = expanded ? 'Show more ▾' : 'Show less ▴';
        });
        block.style.display = 'none';
        el.appendChild(toggle);
      }

      el.appendChild(block);
    }

    return el;
  }

  // ─── Diff preview ─────────────────────────────────────────────
  function _diffPreview(oldStr, newStr) {
    const wrapper = document.createElement('div');
    wrapper.className = 'perm-diff';

    const maxLines = 8;

    if (oldStr) {
      const block = document.createElement('div');
      block.className = 'perm-diff-block perm-diff-old';
      const lines = oldStr.split('\n').slice(0, maxLines);
      block.textContent = lines.join('\n') + (oldStr.split('\n').length > maxLines ? '\n…' : '');
      wrapper.appendChild(block);
    }

    if (newStr) {
      const block = document.createElement('div');
      block.className = 'perm-diff-block perm-diff-new';
      const lines = newStr.split('\n').slice(0, maxLines);
      block.textContent = lines.join('\n') + (newStr.split('\n').length > maxLines ? '\n…' : '');
      wrapper.appendChild(block);
    }

    return wrapper;
  }

  // ─── Code block ───────────────────────────────────────────────
  function _codeBlock(text, lang) {
    const wrapper = document.createElement('div');
    wrapper.className = 'perm-code-wrapper';

    const pre = document.createElement('pre');
    pre.className = 'perm-code';

    const code = document.createElement('code');
    code.className = lang ? `lang-${lang}` : '';
    code.textContent = text;

    pre.appendChild(code);
    wrapper.appendChild(pre);
    return wrapper;
  }

  function _esc(str) {
    if (!str) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  return { buildPermissionPreview };
})();
