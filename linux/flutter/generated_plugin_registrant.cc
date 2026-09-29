//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <sqlite3_flutter_libs/sqlite3_flutter_libs_plugin.h>
#include <thermal_printer_flutter/thermal_printer_flutter_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) sqlite3_flutter_libs_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "Sqlite3FlutterLibsPlugin");
  sqlite3_flutter_libs_plugin_register_with_registrar(sqlite3_flutter_libs_registrar);
  g_autoptr(FlPluginRegistrar) thermal_printer_flutter_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "ThermalPrinterFlutterPlugin");
  thermal_printer_flutter_plugin_register_with_registrar(thermal_printer_flutter_registrar);
}
