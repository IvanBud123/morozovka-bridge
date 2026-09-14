/**
 * morozovka-bridge — общие утилиты фронтенда.
 */

// Словарь HTML-экранирования.
// Ключи со символом " обёрнуты в одинарные кавычки, с символом ' — в двойные.
const HTML_ESCAPES = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
};

const HTML_ESCAPE_RE = /[&<>"']/g;

/**
 * Экранирует спецсимволы HTML в строке.
 * @param {*} value — что угодно, будет приведено к строке.
 * @returns {string}
 */
function escapeHtml(value) {
  return String(value).replace(HTML_ESCAPE_RE, (ch) => HTML_ESCAPES[ch]);
}

/**
 * Клик по строке таблицы (tr[data-id]) — переход на детали сервиса.
 * Игнорирует клики по ссылкам и кнопкам внутри строки.
 */
document.addEventListener("click", (e) => {
  const row = e.target.closest("tr[data-id]");
  if (!row) return;
  if (e.target.closest("a")) return;
  if (e.target.closest("button")) return;
  window.location.href = `/services/${row.dataset.id}`;
});
