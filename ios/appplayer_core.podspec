Pod::Spec.new do |s|
  s.name             = 'appplayer_core'
  s.version          = '0.1.12'
  s.summary          = 'AppPlayer Core native platform integration (FR-PLATFORM).'
  s.description      = <<-DESC
Native iOS side of appplayer_core: background execution, OS permissions, and
notifications for the Platform Integration Foundation.
                       DESC
  s.homepage         = 'https://app-appplayer.github.io/makemind'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'makemind' => 'jsha2k@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
