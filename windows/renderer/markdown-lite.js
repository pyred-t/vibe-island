/**
 * Claude Island Windows — Lightweight Markdown Renderer
 * Covers common patterns: code blocks, inline code, bold, italic, headings, lists, links.
 * No external dependencies.
 */

const MarkdownLite = (() => {

  /**
   * Render markdown string to sanitized HTML.
   * @param {string} md
   * @returns {string}
   */
  function render(md) {
    if (!md) return '';

    // Escape HTML first
    let html = _esc(md);

    // Fenced code blocks: ```lang\n...\n```
    html = html.replace(/```(\w*)\n([\s\S]*?)```/g, (_, lang, code) => {
      const cls = lang ? ` class="lang-${lang}"` : '';
      return `<pre class="md-code-block"><code${cls}>${code}</code></pre>`;
    });

    // Inline code: `code`
    html = html.replace(/`([^`\n]+)`/g, '<code class="md-inline-code">$1</code>');

    // Bold: **text** or __text__
    html = html.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
    html = html.replace(/__(.+?)__/g, '<strong>$1</strong>');

    // Italic: *text* or _text_
    html = html.replace(/(?<!\w)\*([^*\n]+)\*(?!\w)/g, '<em>$1</em>');
    html = html.replace(/(?<!\w)_([^_\n]+)_(?!\w)/g, '<em>$1</em>');

    // Headings
    html = html.replace(/^### (.+)$/gm, '<div class="md-h3">$1</div>');
    html = html.replace(/^## (.+)$/gm, '<div class="md-h2">$1</div>');
    html = html.replace(/^# (.+)$/gm, '<div class="md-h1">$1</div>');

    // Links
    html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a class="md-link" href="$2" title="$2">$1</a>');

    // Lists — group consecutive list lines into <ul>/<ol>
    html = html.replace(/((?:^[\-\*] .+\n?)+)/gm, (block) => {
      const items = block.trim().split('\n').map(line =>
        `<li>${line.replace(/^[\-\*] /, '')}</li>`
      ).join('');
      return `<ul class="md-ul">${items}</ul>`;
    });
    html = html.replace(/((?:^\d+\. .+\n?)+)/gm, (block) => {
      const items = block.trim().split('\n').map(line =>
        `<li>${line.replace(/^\d+\. /, '')}</li>`
      ).join('');
      return `<ol class="md-ol">${items}</ol>`;
    });

    // Line breaks — collapse multiple blank lines into one
    html = html.replace(/\n{2,}/g, '\n');
    html = html.replace(/\n/g, '<br>');

    // Clean up <br> around block elements
    html = html.replace(/<\/pre><br>/g, '</pre>');
    html = html.replace(/<br><pre/g, '<pre');
    html = html.replace(/<\/(ul|ol|div)><br>/g, '</$1>');
    html = html.replace(/<br><(ul|ol|div)/g, '<$1');

    return html;
  }

  function _esc(str) {
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  return { render };
})();
