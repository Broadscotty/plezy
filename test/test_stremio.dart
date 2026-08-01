import "dart:convert";
import "package:http/http.dart" as http;

void main() async {
  // 1. Test manifest fetch
  print("=== TEST 1: Cinemeta manifest ===");
  try {
    var uri = Uri.parse("https://v3-cinemeta.strem.io/manifest.json");
    var resp = await http.Client().get(uri, headers: {"User-Agent": "Plezy/1.0"});
    print("Status: ${resp.statusCode}");
    if (resp.statusCode == 200) {
      var json = jsonDecode(resp.body);
      var catalogs = json["catalogs"] as List;
      print("Catalogs: ${catalogs.length}");
      for (var c in catalogs) {
        print("  ${c["type"]}/${c["id"]} - ${c["name"]} (extraRequired: ${c["extraRequired"]})");
      }
    }
  } catch (e) {
    print("FAILED: $e");
  }

  // 2. Test catalog fetch (exact same URL the code builds)
  print("\n=== TEST 2: cinemeta-catalogs movie/top ===");
  try {
    var url = "https://cinemeta-catalogs.strem.io/top/catalog/movie/top.json?skip=0";
    var resp = await http.Client().get(Uri.parse(url), headers: {"User-Agent": "Plezy/1.0"});
    print("Status: ${resp.statusCode}");
    if (resp.statusCode == 200) {
      var json = jsonDecode(resp.body);
      var metas = json["metas"] as List?;
      print("Metas: ${metas?.length ?? 0}");
      if (metas != null && metas.isNotEmpty) {
        var m = metas[0] as Map<String, dynamic>;
        print("First: ${m["name"]} (id=${m["id"]}, type=${m["type"]})");
      }
    }
  } catch (e) {
    print("FAILED: $e");
  }

  // 3. Test series catalog
  print("\n=== TEST 3: cinemeta-catalogs series/top ===");
  try {
    var url = "https://cinemeta-catalogs.strem.io/top/catalog/series/top.json?skip=0";
    var resp = await http.Client().get(Uri.parse(url), headers: {"User-Agent": "Plezy/1.0"});
    print("Status: ${resp.statusCode}");
    if (resp.statusCode == 200) {
      var json = jsonDecode(resp.body);
      var metas = json["metas"] as List?;
      print("Metas: ${metas?.length ?? 0}");
    }
  } catch (e) {
    print("FAILED: $e");
  }

  // 4. Test v3-cinemeta direct path
  print("\n=== TEST 4: v3-cinemeta direct ===");
  try {
    var url = "https://v3-cinemeta.strem.io/catalog/movie/top.json?skip=0";
    var resp = await http.Client().get(Uri.parse(url), headers: {"User-Agent": "Plezy/1.0"});
    print("Status: ${resp.statusCode}");
    if (resp.statusCode == 200) {
      var json = jsonDecode(resp.body);
      var metas = json["metas"] as List?;
      print("Metas: ${metas?.length ?? 0}");
    }
  } catch (e) {
    print("FAILED: $e");
  }
}
