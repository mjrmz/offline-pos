//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <sqlite3_flutter_libs/sqlite3_flutter_libs_plugin.h>
#include <thermal_printer_flutter/thermal_printer_flutter_plugin_c_api.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  Sqlite3FlutterLibsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("Sqlite3FlutterLibsPlugin"));
  ThermalPrinterFlutterPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ThermalPrinterFlutterPluginCApi"));
}
