// Run in the page Safari shares: what it says of itself, and what is selected.
var GetPageInfo = function() {};
GetPageInfo.prototype = {
    run: function(args) {
        var meta = function(name) {
            var el = document.querySelector('meta[property="' + name + '"], meta[name="' + name + '"]');
            return el && el.content ? el.content : "";
        };
        args.completionFunction({
            url: document.URL,
            title: meta("og:title") || document.title || "",
            description: meta("og:description") || meta("description") || "",
            selection: String(window.getSelection ? window.getSelection() : "")
        });
    },
    finalize: function(args) {}
};
var ExtensionPreprocessingJS = new GetPageInfo();
