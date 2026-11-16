// Erhu Server: Erhu's name in Navidrome's web interface (the look itself is theme.css).
(function () {
  "use strict";
  var fix = function () {
    if (document.title.indexOf("Navidrome") >= 0) document.title = document.title.replace(/Navidrome/g, "Erhu");
    // The top bar's title and the sign-in card's heading.
    document.querySelectorAll("header h6, .MuiCard-root a[href*='navidrome.org']").forEach(function (el) {
      var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      for (var node = walker.nextNode(); node; node = walker.nextNode()) {
        if (node.nodeValue.indexOf("Navidrome") >= 0) node.nodeValue = node.nodeValue.replace(/Navidrome/g, "Erhu");
      }
    });
  };
  var pending = false;
  new MutationObserver(function () {
    if (pending) return;
    pending = true;
    requestAnimationFrame(function () { pending = false; fix(); });
  }).observe(document.documentElement, { subtree: true, childList: true, characterData: true });
  fix();
})();
