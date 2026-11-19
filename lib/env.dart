// One place that reads configuration. Real environment variables win, then the
// .env file, then the fallback. Dart Frog does not load .env on its own.
import 'package:dotenv/dotenv.dart';

final _env = DotEnv(includePlatformEnvironment: true)..load();

String envValue(String key, String fallback) => _env[key] ?? fallback;
