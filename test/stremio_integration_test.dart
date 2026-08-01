import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:plezy/services/stremio/stremio_addon_client.dart';

void main() async {
  print('=== INTEGRATION TEST: StremioAddonClient (persistent) ===');
  
  print('\n--- Test 1: Persistent client, manifest + two catalogs ---');
  final client = StremioAddonClient(addonUrl: 'https://v3-cinemeta.strem.io');
  
  try {
    final manifest = await client.fetchManifest();
    final cats = manifest['catalogs'] as List;
    print('Manifest OK: id=' + manifest['id'].toString() + ', catalogs=' + cats.length.toString());
  } catch (e) {
    print('Manifest FAILED: ' + e.toString());
  }
  
  try {
    final movies = await client.fetchCatalog('movie', 'top');
    print('Movie/top: ' + movies.length.toString() + ' items');
    if (movies.isNotEmpty) {
      print('  First: ' + (movies[0].name ?? '?') + ' (' + movies[0].id + ')');
    }
  } catch (e) {
    print('Movie/top FAILED: ' + e.toString());
  }
  
  try {
    final featured = await client.fetchCatalog('movie', 'imdbRating');
    print('Movie/imdbRating: ' + featured.length.toString() + ' items');
  } catch (e) {
    print('Movie/imdbRating FAILED: ' + e.toString());
  }
  
  print('\n--- Test 2: New http.Client() per call ---');
  try {
    var resp = await http.Client().get(
      Uri.parse('https://v3-cinemeta.strem.io/catalog/movie/top.json'),
      headers: {'User-Agent': 'Plezy/1.0'},
    );
    print('Status: ' + resp.statusCode.toString());
    var json = jsonDecode(resp.body);
    var metas = json['metas'] as List?;
    print('Metas: ' + (metas?.length ?? 0).toString());
  } catch (e) {
    print('Test 2 FAILED: ' + e.toString());
  }
  
  print('\n--- Test 3: Direct cinemeta-catalogs ---');
  try {
    var resp = await http.Client().get(
      Uri.parse('https://cinemeta-catalogs.strem.io/top/catalog/movie/top.json'),
      headers: {'User-Agent': 'Plezy/1.0'},
    );
    print('Status: ' + resp.statusCode.toString());
    var json = jsonDecode(resp.body);
    var metas = json['metas'] as List?;
    print('Metas: ' + (metas?.length ?? 0).toString());
  } catch (e) {
    print('Test 3 FAILED: ' + e.toString());
  }
  
  client.close();
  print('\n=== ALL TESTS COMPLETE ===');
}
