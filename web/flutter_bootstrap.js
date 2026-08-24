{{flutter_js}}
{{flutter_build_config}}

// Keep the exported application self-contained. Flutter's default bootstrap
// loads CanvasKit from gstatic.com even though `flutter build web` emits a
// local copy. That makes startup depend on an external CDN and can fail on
// restricted networks.
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "canvaskit/",
  },
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
});
