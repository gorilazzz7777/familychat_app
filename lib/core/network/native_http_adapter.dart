import 'package:dio/dio.dart';

import 'native_http_adapter_stub.dart'
    if (dart.library.io) 'native_http_adapter_io.dart' as impl;

/// Mobile/desktop: Cronet (Android) / URLSession (Apple). Web: no-op.
void configureNativeHttpAdapter(Dio dio) => impl.configureNativeHttpAdapter(dio);
