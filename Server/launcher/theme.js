// Erhu Server: the Erhu theme's switch, Erhu's name and the About box in Navidrome's web
// interface (the look itself is theme.css, which applies while <html> has the erhu-theme class).
(function () {
  "use strict";
  var root = document.documentElement;
  var KEY = "erhu.theme";

  var erhuOn = function () {
    try { return localStorage.getItem(KEY) !== "off"; } catch (e) { return true; }
  };
  var setErhu = function (on) {
    try { localStorage.setItem(KEY, on ? "on" : "off"); } catch (e) { /* private browsing */ }
    root.classList.toggle("erhu-theme", on);
  };

  var swapName = function (el) {
    var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (var node = walker.nextNode(); node; node = walker.nextNode()) {
      if (node.nodeValue.indexOf("Navidrome") >= 0) node.nodeValue = node.nodeValue.replace(/Navidrome/g, "Erhu");
    }
  };

  // Personal settings → Theme: "Erhu" first in the list. Picking it keeps Navidrome on its Dark
  // theme underneath; picking any other theme turns Erhu's off, so that theme applies alone.
  var fixThemePicker = function () {
    var select = document.getElementById("mui-component-select-theme");
    if (!select) return;
    // Change the label's own text, so Navidrome can still change it to another theme's name.
    var label = select.firstChild;
    if (erhuOn() && label && label.nodeType === 3 && label.nodeValue !== "Erhu") label.nodeValue = "Erhu";
    var list = document.querySelector("[role=listbox]");
    if (!list || select.getAttribute("aria-expanded") !== "true" || list.querySelector("[data-value=ERHU_THEME]")) return;
    var dark = list.querySelector("[data-value=DarkTheme]");
    var first = list.querySelector("[role=option]");
    if (!dark || !first) return;
    var erhu = first.cloneNode(true);
    erhu.setAttribute("data-value", "ERHU_THEME");
    erhu.textContent = "Erhu";
    list.insertBefore(erhu, first);
    list.querySelectorAll("[role=option]").forEach(function (option) {
      var mine = option === erhu;
      var selected = erhuOn() ? mine : option.classList.contains("Mui-selected") && !mine;
      option.classList.toggle("Mui-selected", selected);
      if (!selected) option.classList.remove("Mui-focusVisible");
      option.setAttribute("aria-selected", selected ? "true" : "false");
    });
    erhu.addEventListener("click", function (event) {
      event.stopPropagation();
      dark.click(); // closes the list; Navidrome stays on (or moves to) its Dark theme
      setErhu(true);
      fixThemePicker();
    });
    list.addEventListener("click", function (event) {
      var option = event.target.closest("[role=option]");
      if (option && option !== erhu) setErhu(false);
    }, true);
  };

  // About: Erhu's details, and the credit to Navidrome, the music server underneath.
  var fixAbout = function () {
    var dialog = document.querySelector("[aria-labelledby=about-dialog-title]");
    if (!dialog) return;
    var title = dialog.querySelector("#about-dialog-title h5, #about-dialog-title h2, #about-dialog-title h6");
    if (title && title.textContent !== "Erhu") title.textContent = "Erhu";
    var table = dialog.querySelector("#about-panel table");
    if (!table || table.getAttribute("data-erhu")) return;
    table.setAttribute("data-erhu", "1");
    var navidrome = "";
    var navidromeLink = "https://www.navidrome.org";
    table.querySelectorAll("tr").forEach(function (row, index) {
      if (index === 0) {
        var cell = row.querySelector("td");
        var link = cell && cell.querySelector("a");
        navidrome = cell ? cell.textContent.trim() : "";
        if (link) navidromeLink = link.href;
        return;
      }
      row.remove();
    });
    var meta = document.querySelector("meta[name=erhu-server-version]");
    var version = meta ? meta.content : "";
    var body = table.querySelector("tbody") || table;
    var first = body.querySelector("tr");
    var row = function (label, text, href) {
      var tr = first.cloneNode(true);
      tr.querySelector("th").textContent = label;
      var td = tr.querySelector("td");
      td.textContent = "";
      if (href) {
        var a = document.createElement("a");
        a.href = href; a.target = "_blank"; a.rel = "noopener noreferrer"; a.textContent = text;
        td.appendChild(a);
      } else {
        td.textContent = text;
      }
      return tr;
    };
    body.insertBefore(row("Erhu Server:", version && version !== "dev" ? "Version " + version : "Development build"), first);
    first.replaceWith(row("Music server:", "Navidrome " + navidrome, navidromeLink));
    var credit = document.createElement("p");
    credit.className = "erhu-about-credit";
    credit.innerHTML = 'Erhu’s web player and music server are built on <a href="https://www.navidrome.org" target="_blank" rel="noopener noreferrer">Navidrome</a>, ' +
      'free software by Deluan Quintão and contributors, licensed under the GNU GPL v3. ' +
      'Its source code: <a href="https://github.com/navidrome/navidrome" target="_blank" rel="noopener noreferrer">github.com/navidrome/navidrome</a>.';
    table.parentNode.insertBefore(credit, table.nextSibling);
  };

  var fix = function () {
    if (document.title.indexOf("Navidrome") >= 0) document.title = document.title.replace(/Navidrome/g, "Erhu");
    // The top bar's title and the sign-in card's heading.
    document.querySelectorAll("header h6, .MuiCard-root a[href*='navidrome.org']").forEach(swapName);
    fixThemePicker();
    fixAbout();
  };
  var pending = false;
  new MutationObserver(function () {
    if (pending) return;
    pending = true;
    requestAnimationFrame(function () { pending = false; fix(); });
  }).observe(root, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ["aria-expanded"] });
  fix();
})();
