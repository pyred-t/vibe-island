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

    // Italic: *text* or _text_ (but not inside words with underscores)
    html = html.replace(/(?<!\w)\*([^*\n]+)\*(?!\w)/g, '<em>$1</em>');
    html = html.replace(/(?<!\w)_([^_\n]+)_(?!\w)/g, '<em>$1</em>');

    // Headings: # H1, ## H2, ### H3
    html = html.replace(/^### (.+)$/gm, '<div class="md-h3">$1</div>');
    html = html.replace(/^## (.+)$/gm, '<div class="md-h2">$1</div>');
    html = html.replace(/^# (.+)$/gm, '<div class="md-h1">$1</div>');

    // Unordered lists: - item or * item
    html = html.replace(/^[\-\*] (.+)$/gm, '<div class="md-li">• $1</div>');

    // Ordered lists: 1. item
    html = html.replace(/^\d+\. (.+)$/gm, '<div class="md-li-ordered">$1</div>');

    // Links: [text](url)
    html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a class="md-link" href="$2" title="$2">$1</a>');

    // Line breaks → <br> (but not inside code blocks)
    html = html.replace(/\n/g, '<br>');

    // Clean up double <br> from code blocks
    html = html.replace(/<\/pre><br>/g, '</pre>');
    html = html.replace(/<br><pre/g, '<pre');

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
