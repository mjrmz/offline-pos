enum PrinterConnection { lan, usb, bluetooth }

class PrinterSettings {
  final bool enabled;
  final PrinterConnection transport;
  final String host;
  final int port;
  final String deviceId;
  final String deviceName;
  final int widthMm;
  final bool drawerEnabled;
  final String storeName;

  const PrinterSettings({
    this.enabled = false,
    this.transport = PrinterConnection.lan,
    this.host = '',
    this.port = 9100,
    this.deviceId = '',
    this.deviceName = '',
    this.widthMm = 80,
    this.drawerEnabled = false,
    this.storeName = '',
  });

  bool get configured =>
      enabled &&
      switch (transport) {
        PrinterConnection.lan =>
          host.trim().isNotEmpty && port > 0 && port <= 65535,
        PrinterConnection.usb ||
        PrinterConnection.bluetooth =>
          deviceId.isNotEmpty,
      };
}
