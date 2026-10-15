# flutter_inappwebview_windows 0.6.0 keeps WinRT Composition resources in
# static smart pointers. Releasing them during DLL unload can fail fast in
# dcomp.dll (upstream flutter_inappwebview issue #2733). Patch a build-local
# source copy; never modify the user's shared Pub cache.
set(QQM_WEBVIEW_TARGET flutter_inappwebview_windows_plugin)
if(TARGET ${QQM_WEBVIEW_TARGET})
  get_target_property(QQM_WEBVIEW_DIR ${QQM_WEBVIEW_TARGET} SOURCE_DIR)
  set(QQM_MANAGER_FILE "in_app_webview/in_app_webview_manager.cpp")
  file(READ "${QQM_WEBVIEW_DIR}/${QQM_MANAGER_FILE}" QQM_MANAGER_SOURCE)
  foreach(QQM_EXPECTED "RegisterClass(&windowClass_);" "debugLog(\"dealloc InAppWebViewManager\");")
    string(FIND "${QQM_MANAGER_SOURCE}" "${QQM_EXPECTED}" QQM_FOUND)
    if(QQM_FOUND LESS 0)
      message(FATAL_ERROR "WebView shutdown patch requires review for this plugin version")
    endif()
  endforeach()

  string(REPLACE "namespace flutter_inappwebview_plugin\n{"
    "namespace flutter_inappwebview_plugin\n{\n  static std::map<InAppWebViewManager*, int> qqm_shutdown_delegates;"
    QQM_MANAGER_SOURCE "${QQM_MANAGER_SOURCE}")
  string(REPLACE "RegisterClass(&windowClass_);" [=[RegisterClass(&windowClass_);
    // This application owns one Flutter engine. Run while the UI thread,
    // dispatcher, WinRT and COM are all still alive, before engine teardown.
    qqm_shutdown_delegates[this] = plugin->registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
        if (message == WM_DESTROY) {
          webViews.clear();
          keepAliveWebViews.clear();
          windowWebViews.clear();
          compositor_ = nullptr;
          graphics_context_ = nullptr;
          dispatcher_queue_controller_ = nullptr;
          rohelper_ = nullptr;
          valid_ = false;
        }
        return std::nullopt;
      });]=] QQM_MANAGER_SOURCE "${QQM_MANAGER_SOURCE}")
  string(REPLACE "debugLog(\"dealloc InAppWebViewManager\");" [=[debugLog("dealloc InAppWebViewManager");
    auto shutdownDelegate = qqm_shutdown_delegates.find(this);
    if (shutdownDelegate != qqm_shutdown_delegates.end()) {
      plugin->registrar->UnregisterTopLevelWindowProcDelegate(shutdownDelegate->second);
      qqm_shutdown_delegates.erase(shutdownDelegate);
    }]=] QQM_MANAGER_SOURCE "${QQM_MANAGER_SOURCE}")
  string(REPLACE "windowWebViews.clear();\n    UnregisterClass" [=[windowWebViews.clear();
    compositor_ = nullptr;
    graphics_context_ = nullptr;
    dispatcher_queue_controller_ = nullptr;
    rohelper_ = nullptr;
    valid_ = false;
    UnregisterClass]=] QQM_MANAGER_SOURCE "${QQM_MANAGER_SOURCE}")

  set(QQM_PATCH_DIR "${CMAKE_BINARY_DIR}/qqm_patched_webview")
  file(COPY "${QQM_WEBVIEW_DIR}/" DESTINATION "${QQM_PATCH_DIR}")
  file(WRITE "${QQM_PATCH_DIR}/${QQM_MANAGER_FILE}" "${QQM_MANAGER_SOURCE}")
  get_target_property(QQM_WEBVIEW_SOURCES ${QQM_WEBVIEW_TARGET} SOURCES)
  set(QQM_PATCHED_SOURCES "")
  foreach(QQM_SOURCE IN LISTS QQM_WEBVIEW_SOURCES)
    if(QQM_SOURCE STREQUAL QQM_MANAGER_FILE OR QQM_SOURCE STREQUAL "${QQM_WEBVIEW_DIR}/${QQM_MANAGER_FILE}")
      list(APPEND QQM_PATCHED_SOURCES "${QQM_PATCH_DIR}/${QQM_MANAGER_FILE}")
    elseif(IS_ABSOLUTE "${QQM_SOURCE}" OR QQM_SOURCE MATCHES "^\\$<")
      list(APPEND QQM_PATCHED_SOURCES "${QQM_SOURCE}")
    else()
      list(APPEND QQM_PATCHED_SOURCES "${QQM_WEBVIEW_DIR}/${QQM_SOURCE}")
    endif()
  endforeach()
  set_property(TARGET ${QQM_WEBVIEW_TARGET} PROPERTY SOURCES "${QQM_PATCHED_SOURCES}")
endif()
