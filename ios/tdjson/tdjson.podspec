Pod::Spec.new do |s|
  s.name             = 'tdjson'
  s.version          = '1.8.65'
  s.summary          = 'Prebuilt TDLib tdjson static library for FamilyChat'
  s.homepage         = 'https://github.com/up9cloud/ios-libtdjson'
  s.license          = { :type => 'BSL-1.0' }
  s.author           = { 'FamilyChat' => 'local' }
  s.source           = { :path => '.' }
  s.ios.deployment_target = '14.0'
  s.vendored_frameworks = 'libtdjson-static.xcframework'
  s.source_files = 'TdlibKeepSymbols.m'
  s.libraries = 'c++'
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++14',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC',
  }
end
