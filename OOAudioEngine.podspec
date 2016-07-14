Pod::Spec.new do |s|

s.name     = 'OOAudioEngine'
s.version  = '0.0.2'
s.license  = 'MIT'
s.summary  = 'A leaner audio engine based on audio unit'
s.homepage = 'https://github.com/oyh5233/OOAudioEngine'
s.author   = { 'oyh5233' => 'oyh5233@outlook.com' }
s.source   = { :git => 'https://github.com/oyh5233/OOAudioEngine.git',
:tag => "#{s.version}" }
s.description = 'A leaner audio Engine based on audio unit.easy to use'
s.requires_arc   = true
s.ios.deployment_target = '7.0'
s.source_files = 'OOAudioEngine/Classes/*.{h,m}'
s.framework = 'AVFoundation'

end
