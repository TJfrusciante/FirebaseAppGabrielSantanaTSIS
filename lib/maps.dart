import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:geoflutterfire_plus/geoflutterfire_plus.dart';
import 'package:geolocator/geolocator.dart';

enum MapEditorMode { initial, finalPoint }

class MapViewerEditorPage extends StatefulWidget {
 final DocumentReference<Map<String, dynamic>> noteRef;
 final ll.LatLng? initialLatLng;
 final ll.LatLng? finalLatLng;
 final double? initialZoom;
 final String? initialAddress;
 final String? finalAddress;
 final String? initialPolyline6;
 final double? initialDistanceM;
 final double? initialDurationS;
 final String? orsApiKey;
 final String orsProfile;

 const MapViewerEditorPage({
   super.key,
   required this.noteRef,
   this.initialLatLng,
   this.finalLatLng,
   this.initialZoom,
   this.initialAddress,
   this.finalAddress,
   this.initialPolyline6,
   this.initialDistanceM,
   this.initialDurationS,
   this.orsApiKey,
   this.orsProfile = 'driving-car',
 });

 @override
 State<MapViewerEditorPage> createState() => _MapViewerEditorPageState();
}

class _MapViewerEditorPageState extends State<MapViewerEditorPage> {
 final MapController _mapController = MapController();

 static const _worldCenter = ll.LatLng(0, 0);
 static const double _worldZoom = 1.5;

 ll.LatLng? _initialPoint;
 ll.LatLng? _finalPoint;
 String _initialAddress = '';
 String _finalAddress = '';

 List<ll.LatLng> _routePoints = [];
 String? _routePolyline6;
 double? _routeDistanceM;
 double? _routeDurationS;

 double _zoom = _worldZoom;
 bool _saving = false;
 MapEditorMode _mode = MapEditorMode.initial;

 String? _orsApiKey;

 @override
 void initState() {
   super.initState();
   _initialPoint = widget.initialLatLng;
   _finalPoint = widget.finalLatLng;
   _initialAddress = widget.initialAddress ?? '';
   _finalAddress = widget.finalAddress ?? '';
   _zoom = widget.initialZoom ?? _worldZoom;

   WidgetsBinding.instance.addPostFrameCallback((_) async {
     _orsApiKey = (widget.orsApiKey != null && widget.orsApiKey!.isNotEmpty)
         ? widget.orsApiKey!.trim()
         : await _getOrsApiKey();

     final savedPolyline = (widget.initialPolyline6 ?? '').trim();
     if (savedPolyline.isNotEmpty) {
       final pts = _tryDecodePolyline(savedPolyline);
       if (pts.isNotEmpty) {
         _routePolyline6 = savedPolyline;
         _routePoints = pts;
         _routeDistanceM = widget.initialDistanceM;
         _routeDurationS = widget.initialDurationS;
         if (mounted) setState(() {});
         _fitToPoints(_routePoints);
         return;
       }
     }

     if (_initialPoint == null) {
       await _setInitialFromGPS();
     }

     if (_initialPoint != null && _finalPoint != null) {
       await _fetchRoute(_initialPoint!, _finalPoint!);
     } else if (_initialPoint != null) {
       _safeMove(_initialPoint!, _zoom);
     } else if (_finalPoint != null) {
       _safeMove(_finalPoint!, _zoom);
     } else {
       _safeMove(_worldCenter, _worldZoom);
     }
   });
 }

 Future<void> _setInitialFromGPS() async {
   final permission = await _ensureLocationPermission();
   if (!permission) return;
   try {
     final pos = await Geolocator.getCurrentPosition();
     final p = ll.LatLng(pos.latitude, pos.longitude);
     setState(() {
       _initialPoint = p;
       if (_zoom <= _worldZoom) _zoom = 14;
     });
     _safeMove(p, _zoom);
   } catch (e, s) {
     developer.log('Failed to get current position', error: e, stackTrace: s);
   }
 }

 Future<bool> _ensureLocationPermission() async {
   final enabled = await Geolocator.isLocationServiceEnabled();
   if (!enabled) {
     if (mounted) {
       ScaffoldMessenger.of(context).showSnackBar(
         const SnackBar(content: Text('Location service is disabled.')),
       );
     }
     return false;
   }
   LocationPermission permission = await Geolocator.checkPermission();
   if (permission == LocationPermission.denied) {
     permission = await Geolocator.requestPermission();
   }
   if (permission == LocationPermission.denied ||
       permission == LocationPermission.deniedForever) {
     if (mounted) {
       ScaffoldMessenger.of(context).showSnackBar(
         const SnackBar(content: Text('Location permission denied.')),
       );
     }
     return false;
   }
   return true;
 }

 Future<String?> _getOrsApiKey() async {
   try {
     final snap = await FirebaseFirestore.instance
         .collection('config')
         .doc('osr')
         .get();
     final data = snap.data();
     final k = (data?['key'] ?? '').toString().trim();
     if (k.isNotEmpty) return k;
   } catch (e, s) {
     developer.log('Failed to get OSR API key from Firestore',
         error: e, stackTrace: s);
   }
   const fromDefine = String.fromEnvironment(
     'ORS_API_KEY',
     defaultValue: '',
   );
   return fromDefine.isNotEmpty ? fromDefine : null;
 }

 void _safeMove(ll.LatLng center, double zoom) {
   try {
     _mapController.move(center, zoom);
   } catch (e, s) {
     developer.log('Failed to move map', error: e, stackTrace: s);
   }
 }

 List<ll.LatLng> _sanitizePoints(List<ll.LatLng> pts) {
   return pts
       .where(
         (p) =>
             p.latitude.isFinite &&
             p.longitude.isFinite &&
             p.latitude >= -90 &&
             p.latitude <= 90 &&
             p.longitude >= -180 &&
             p.longitude <= 180,
       )
       .toList();
 }

 void _fitToPoints(List<ll.LatLng> pts) {
   final clean = _sanitizePoints(pts);
   if (clean.isEmpty) return;
   try {
     final bounds = LatLngBounds.fromPoints(clean);
     _mapController.fitCamera(
       CameraFit.bounds(
         bounds: bounds,
         padding: const EdgeInsets.all(32), // Increased padding
       ),
     );
   } catch (e, s) {
     developer.log('Failed to fit map to bounds', error: e, stackTrace: s);
     if (clean.isNotEmpty) {
       _safeMove(clean.first, _zoom);
     }
   }
 }

 Future<String> _reverseGeocode(ll.LatLng point) async {
   final uri = Uri.parse(
     'https://nominatim.openstreetmap.org/reverse'
     '?lat=${point.latitude}&lon=${point.longitude}'
     '&format=json&addressdetails=1',
   );
   try {
     final resp = await http.get(
       uri,
       headers: const {"Accept": "application/json"},
     );
     if (resp.statusCode == 200) {
       final json = jsonDecode(resp.body) as Map<String, dynamic>;
       return (json['display_name'] ?? '').toString();
     }
     return 'Address unavailable (HTTP ${resp.statusCode})';
   } catch (e) {
     return 'Address unavailable ($e)';
   }
 }

 List<ll.LatLng> _decodePolyline(String polyline, {int precision = 6}) {
   final List<ll.LatLng> points = [];
   int index = 0, lat = 0, lng = 0;
   int shift, result, b;
   final factor = math.pow(10, precision);
   while (index < polyline.length) {
     shift = 0;
     result = 0;
     do {
       b = polyline.codeUnitAt(index++) - 63;
       result |= (b & 0x1f) << shift;
       shift += 5;
     } while (b >= 0x20);
     final dlat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
     lat += dlat;

     shift = 0;
     result = 0;
     do {
       b = polyline.codeUnitAt(index++) - 63;
       result |= (b & 0x1f) << shift;
       shift += 5;
     } while (b >= 0x20);
     final dlng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
     lng += dlng;

     points.add(ll.LatLng(lat / factor, lng / factor));
   }
   return points;
 }

 String _encodePolyline(List<ll.LatLng> pts, {int precision = 6}) {
   final factor = math.pow(10, precision);
   int prevLat = 0, prevLng = 0;
   final sb = StringBuffer();

   void encodeValue(int v) {
     v = v < 0 ? ~(v << 1) : (v << 1);
     while (v >= 0x20) {
       sb.writeCharCode((0x20 | (v & 0x1f)) + 63);
       v >>= 5;
     }
     sb.writeCharCode(v + 63);
   }

   for (final p in pts) {
     final lat = (p.latitude * factor).round();
     final lng = (p.longitude * factor).round();
     encodeValue(lat - prevLat);
     encodeValue(lng - prevLng);
     prevLat = lat;
     prevLng = lng;
   }
   return sb.toString();
 }

 List<ll.LatLng> _tryDecodePolyline(String encoded) {
   var pts = _sanitizePoints(_decodePolyline(encoded, precision: 6));
   if (pts.length < 2) {
     pts = _sanitizePoints(_decodePolyline(encoded, precision: 5));
   }
   return pts;
 }

 Future<void> _fetchRoute(ll.LatLng a, ll.LatLng b) async {
   setState(() {
     _routePoints = [];
     _routeDistanceM = null;
     _routeDurationS = null;
     _routePolyline6 = null;
   });

   final key = _orsApiKey ?? await _getOrsApiKey();
   if (key == null || key.isEmpty) {
     if (mounted) {
       ScaffoldMessenger.of(
         context,
       ).showSnackBar(const SnackBar(content: Text('ORS API key is missing.')));
     }
     return;
   }

   final profile = widget.orsProfile.isEmpty ? 'driving-car' : widget.orsProfile;
   final url = Uri.parse(
     'https://api.openrouteservice.org/v2/directions/$profile/geojson',
   );

   final body = jsonEncode({
     "coordinates": [
       [a.longitude, a.latitude],
       [b.longitude, b.latitude],
     ],
     "instructions": false,
     "geometry": true,
     "geometry_simplify": false,
     "units": "m",
   });

   try {
     final resp = await http.post(
       url,
       headers: {
         "Authorization": key,
         "Content-Type": "application/json",
         "Accept": "application/geo+json",
       },
       body: body,
     );

     if (resp.statusCode == 200) {
       final obj = jsonDecode(resp.body) as Map<String, dynamic>;
       final features = (obj["features"] as List?) ?? [];
       if (features.isEmpty) {
         if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(content: Text('Route not found.')),
           );
         }
         return;
       }

       final feat = features.first as Map<String, dynamic>;
       final props = (feat["properties"] ?? {}) as Map<String, dynamic>;
       final summary = (props["summary"] ?? {}) as Map<String, dynamic>;

       _routeDistanceM = (summary["distance"] as num?)?.toDouble();
       _routeDurationS = (summary["duration"] as num?)?.toDouble();

       final geom = (feat["geometry"] ?? {}) as Map<String, dynamic>;
       final coords = (geom["coordinates"] as List?) ?? [];

       _routePoints = coords
           .map(
             (c) =>
                 ll.LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
           )
           .toList();

       _routePoints = _sanitizePoints(_routePoints);
       if (_routePoints.isEmpty) {
         if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(content: Text('Route not found.')),
           );
         }
         return;
       }

       _routePolyline6 = _encodePolyline(_routePoints, precision: 6);

       if (mounted) setState(() {});
       _fitToPoints(_routePoints);
     } else {
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(
             content: Text('Failed to fetch route (HTTP ${resp.statusCode}).'),
           ),
         );
       }
     }
   } catch (e, s) {
     developer.log('Error fetching route', error: e, stackTrace: s);
     if (mounted) {
       ScaffoldMessenger.of(
         context,
       ).showSnackBar(SnackBar(content: Text('Error fetching route: $e')));
     }
   }
 }

 Future<void> _save() async {
   if (_initialPoint == null) {
     ScaffoldMessenger.of(
       context,
     ).showSnackBar(const SnackBar(content: Text('Set the initial point.')));
     return;
   }

   setState(() => _saving = true);

   try {
     if (_initialAddress.isEmpty) {
       _initialAddress = await _reverseGeocode(_initialPoint!);
     }
     if (_finalPoint != null && _finalAddress.isEmpty) {
       _finalAddress = await _reverseGeocode(_finalPoint!);
     }
     if (_initialPoint != null &&
         _finalPoint != null &&
         (_routePoints.isEmpty || _routePolyline6 == null)) {
       await _fetchRoute(_initialPoint!, _finalPoint!);
       if (_routePoints.isEmpty) {
         if (mounted) setState(() => _saving = false);
         return;
       }
     }

     final Map<String, dynamic> payload = {
       'zoom': _zoom,
       'updatedAt': FieldValue.serverTimestamp(),
     };

     final igfp = GeoFirePoint(
       GeoPoint(_initialPoint!.latitude, _initialPoint!.longitude),
     );
     payload['position'] = igfp.data;
     payload['address'] = _initialAddress;
     payload['initial'] = {'position': igfp.data, 'address': _initialAddress};

     if (_finalPoint != null) {
       final fgfp = GeoFirePoint(
         GeoPoint(_finalPoint!.latitude, _finalPoint!.longitude),
       );
       payload['final'] = {'position': fgfp.data, 'address': _finalAddress};
     } else {
       payload['final'] = FieldValue.delete();
     }

     if (_initialPoint != null && _finalPoint != null) {
       payload['distanceM'] = _routeDistanceM;
       payload['durationS'] = _routeDurationS;
       payload['polyline6'] = _routePolyline6;
       payload['mode'] = widget.orsProfile;
     } else {
       payload['distanceM'] = FieldValue.delete();
       payload['durationS'] = FieldValue.delete();
       payload['polyline6'] = FieldValue.delete();
       payload['mode'] = FieldValue.delete();
     }

     await widget.noteRef.set(payload, SetOptions(merge: true));
     if (!mounted) return;
     ScaffoldMessenger.of(
       context,
     ).showSnackBar(const SnackBar(content: Text('Data saved.')));
     Navigator.pop(context);
   } catch (e, s) {
     developer.log('Failed to save data', error: e, stackTrace: s);
     if (!mounted) return;
     ScaffoldMessenger.of(
       context,
     ).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
   } finally {
     if (mounted) {
       setState(() => _saving = false);
     }
   }
 }

 Future<void> _clearAll() async {
   final ok = await showDialog<bool>(
     context: context,
     builder: (_) => AlertDialog(
       title: const Text('Clear map'),
       content: const Text('Remove location and route?'),
       actions: [
         TextButton(
           onPressed: () => Navigator.pop(context, false),
           child: const Text('Cancel'),
         ),
         FilledButton.tonal(
           onPressed: () => Navigator.pop(context, true),
           child: const Text('Remove'),
         ),
       ],
     ),
   );
   if (ok != true) return;

   try {
     await widget.noteRef.update({
       'position': FieldValue.delete(),
       'address': FieldValue.delete(),
       'zoom': FieldValue.delete(),
       'initial': FieldValue.delete(),
       'final': FieldValue.delete(),
       'distanceM': FieldValue.delete(),
       'durationS': FieldValue.delete(),
       'polyline6': FieldValue.delete(),
       'mode': FieldValue.delete(),
       'updatedAt': FieldValue.serverTimestamp(),
     });
     if (!mounted) return;
     setState(() {
       _initialPoint = null;
       _finalPoint = null;
       _initialAddress = '';
       _finalAddress = '';
       _routePoints = [];
       _routePolyline6 = null;
       _routeDistanceM = null;
       _routeDurationS = null;
       _zoom = _worldZoom;
     });
     ScaffoldMessenger.of(
       context,
     ).showSnackBar(const SnackBar(content: Text('Data removed.')));
   } catch (e, s) {
     developer.log('Failed to clear data', error: e, stackTrace: s);
     if (!mounted) return;
     ScaffoldMessenger.of(
       context,
     ).showSnackBar(SnackBar(content: Text('Failed to remove: $e')));
   }
 }

 void _swapInitialFinal() {
   setState(() {
     final p = _initialPoint;
     _initialPoint = _finalPoint;
     _finalPoint = p;
     final s = _initialAddress;
     _initialAddress = _finalAddress;
     _finalAddress = s;
     _routePoints.clear();
     _routePolyline6 = null;
     _routeDistanceM = null;
     _routeDurationS = null;
     if (_initialPoint != null && _finalPoint != null) {
       _fetchRoute(_initialPoint!, _finalPoint!);
     }
   });
 }

 @override
 Widget build(BuildContext context) {
   final markers = <Marker>[
     if (_initialPoint != null)
       Marker(
         point: _initialPoint!,
         width: 40,
         height: 40,
         child: const Icon(Icons.flag, size: 40, color: Colors.green),
       ),
     if (_finalPoint != null)
       Marker(
         point: _finalPoint!,
         width: 40,
         height: 40,
         child: const Icon(Icons.flag_circle, size: 40, color: Colors.blue),
       ),
   ];

   return Scaffold(
     appBar: AppBar(
       title: const Text('Map'),
       actions: [
         IconButton(
           tooltip: 'Clear',
           onPressed: _saving ? null : _clearAll,
           icon: const Icon(Icons.delete),
         ),
         TextButton.icon(
           onPressed: _saving ? null : _save,
           icon: _saving
               ? const SizedBox(
                   width: 16,
                   height: 16,
                   child: CircularProgressIndicator(strokeWidth: 2),
                 )
               : const Icon(Icons.check),
           label: const Text('Save'),
         ),
       ],
     ),
     body: Column(
       children: [
         Expanded(
           child: FlutterMap(
             mapController: _mapController,
             options: MapOptions(
               initialCenter: _initialPoint ?? _finalPoint ?? _worldCenter,
               initialZoom:
                   (_initialPoint != null || _finalPoint != null) ? _zoom : _worldZoom,
               onTap: (tapPos, point) {
                 setState(() {
                   if (_mode == MapEditorMode.initial) {
                     _initialPoint = point;
                     _initialAddress = '';
                   } else {
                     _finalPoint = point;
                     _finalAddress = '';
                   }
                   _routePoints.clear();
                   _routePolyline6 = null;
                   _routeDistanceM = null;
                   _routeDurationS = null;
                 });
               },
               onPositionChanged: (camera, hasGesture) {
                 if (hasGesture) {
                   _zoom = camera.zoom;
                 }
               },
             ),
             children: [
               TileLayer(
                 urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                 subdomains: const ['a', 'b', 'c'],
                 // TODO: Replace with your app's package name to comply with OSM tile usage policy.
                 // You can use the package_info_plus package to get this dynamically.
                 userAgentPackageName: 'com.example.app',
               ),
               if (_routePoints.isNotEmpty)
                 PolylineLayer(
                   polylines: [
                     Polyline(
                       points: _routePoints,
                       strokeWidth: 5,
                       color: Colors.blue,
                       borderColor: Colors.blue.withOpacity(0.5),
                       borderStrokeWidth: 2,
                     ),
                   ],
                 ),
               MarkerLayer(markers: markers),
             ],
           ),
         ),
         Material(
           elevation: 4,
           child: Padding(
             padding: const EdgeInsets.all(8.0),
             child: Column(
               mainAxisSize: MainAxisSize.min,
               children: [
                 Row(
                   mainAxisAlignment: MainAxisAlignment.center,
                   children: [
                     Wrap(
                       spacing: 8,
                       runSpacing: 8,
                       alignment: WrapAlignment.center,
                       children: [
                         FilterChip(
                           label: const Text('Initial'),
                           selected: _mode == MapEditorMode.initial,
                           onSelected: (v) =>
                               setState(() => _mode = MapEditorMode.initial),
                         ),
                         FilterChip(
                           label: const Text('Final'),
                           selected: _mode == MapEditorMode.finalPoint,
                           onSelected: (v) =>
                               setState(() => _mode = MapEditorMode.finalPoint),
                         ),
                         FilledButton.tonalIcon(
                           onPressed: (_initialPoint != null && _finalPoint != null)
                               ? () => _fetchRoute(_initialPoint!, _finalPoint!)
                               : null,
                           icon: const Icon(Icons.alt_route),
                           label: const Text('Route'),
                         ),
                         OutlinedButton.icon(
                           onPressed: (_initialPoint != null || _finalPoint != null)
                               ? _swapInitialFinal
                               : null,
                           icon: const Icon(Icons.swap_vert),
                           label: const Text('Swap'),
                         ),
                       ],
                     ),
                   ],
                 ),
                 const Divider(height: 16),
                 ListTile(
                   leading: const Icon(Icons.flag, color: Colors.green),
                   title: Text(
                     _initialAddress.isEmpty
                         ? 'Initial: Not defined'
                         : 'Initial: $_initialAddress',
                     maxLines: 2,
                     overflow: TextOverflow.ellipsis,
                   ),
                   trailing: IconButton(
                     tooltip: 'Search address',
                     onPressed: _initialPoint == null || _saving
                         ? null
                         : () async {
                             final addr = await _reverseGeocode(_initialPoint!);
                             if (!mounted) return;
                             setState(() => _initialAddress = addr);
                           },
                     icon: const Icon(Icons.search),
                   ),
                 ),
                 ListTile(
                   leading: const Icon(Icons.flag_circle, color: Colors.blue),
                   title: Text(
                     _finalAddress.isEmpty
                         ? 'Final: Not defined'
                         : 'Final: $_finalAddress',
                     maxLines: 2,
                     overflow: TextOverflow.ellipsis,
                   ),
                   trailing: IconButton(
                     tooltip: 'Search address',
                     onPressed: _finalPoint == null || _saving
                         ? null
                         : () async {
                             final addr = await _reverseGeocode(_finalPoint!);
                             if (!mounted) return;
                             setState(() => _finalAddress = addr);
                           },
                     icon: const Icon(Icons.search),
                   ),
                 ),
                 if (_routeDistanceM != null && _routeDurationS != null)
                   Padding(
                     padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                     child: Row(
                       mainAxisAlignment: MainAxisAlignment.center,
                       children: [
                         const Icon(Icons.route, size: 16),
                         const SizedBox(width: 8),
                         Text(
                           '${(_routeDistanceM! / 1000).toStringAsFixed(2)} km  ·  '
                           '${(_routeDurationS! / 60).toStringAsFixed(0)} min',
                           style: Theme.of(context).textTheme.bodySmall,
                         ),
                       ],
                     ),
                   ),
               ],
             ),
           ),
         ),
       ],
     ),
   );
 }
}
