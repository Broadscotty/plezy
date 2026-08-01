import 'package:plezy/services/stremio/stremio_addon_client.dart';

void main() async {
  print('=== Test 1: Torrentio manifest ===');
  var client = StremioAddonClient(addonUrl: 'https://torrentio.strem.fun');
  print('Normalized URL: ' + client.addonUrl);
  try {
    var m = await client.fetchManifest();
    print('OK: id=' + m['id'].toString());
    print('     name=' + m['name'].toString());
  } catch (e) {
    print('FAILED: ' + e.toString());
  }
  client.close();

  print('\n=== Test 2: /manifest.json appended ===');
  var client2 = StremioAddonClient(addonUrl: 'https://torrentio.strem.fun/manifest.json');
  print('Normalized URL: ' + client2.addonUrl);
  try {
    var m = await client2.fetchManifest();
    print('OK');
  } catch (e) {
    print('FAILED: ' + e.toString());
  }
  client2.close();
}
