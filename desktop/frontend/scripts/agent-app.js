(() => {
  const current = document.currentScript;
  const src = current?.getAttribute("src") || "./scripts/agent-app.js";
  const base = src.replace(/agent-app\.js(?:\?.*)?$/, "");
  const files = [
    "agent-mock-bridge.js",
    "modules/agent-core.js",
    "modules/agent-views.js",
    "modules/agent-bootstrap.js",
  ];

  const alreadyLoaded = (name) =>
    Array.from(document.scripts).some((script) =>
      (script.getAttribute("src") || "").includes(name)
    );

  files.forEach((file) => {
    if (alreadyLoaded(file)) return;
    const script = document.createElement("script");
    script.src = `${base}${file}`;
    script.defer = false;
    document.head.appendChild(script);
  });
})();
