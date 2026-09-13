# Run from any directory: ruby validate_language.rb [path to language file]
require 'json'

def validate_language(data)
  errors = []
  entries = data.fetch('tekster')
  raise 'tekster must be an object' unless entries.is_a?(Hash)
  entries.each do |key, translations|
    unless translations.is_a?(Hash) && translations.keys.sort == %w[en nb tr]
      errors << "#{key}: expected en, nb and tr"
      next
    end
    unless translations.values.all? { |text| text.is_a?(String) && !text.strip.empty? }
      errors << "#{key}: empty or invalid translation"
      next
    end
    placeholders = translations.values.map { |text| text.scan(/\{[^{}]+\}/).sort }
    errors << "#{key}: placeholders differ between languages" unless placeholders.uniq.size == 1
  end
  errors
end

if __FILE__ == $PROGRAM_NAME
  if ARGV == ['--self-test']
    good = { 'tekster' => { 'test' => { 'en' => 'At {sted}', 'nb' => 'På {sted}', 'tr' => 'Oppi {sted}' } } }
    raise 'Valid text rejected' unless validate_language(good).empty?
    bad = Marshal.load(Marshal.dump(good))
    bad['tekster']['test']['en'] = 'At {place}'
    raise 'Placeholder mismatch missed' if validate_language(bad).empty?
    bad['tekster']['test'].delete('tr')
    raise 'Missing language missed' if validate_language(bad).empty?
    bad = Marshal.load(Marshal.dump(good))
    bad['tekster']['test']['nb'] = ''
    raise 'Empty translation missed' if validate_language(bad).empty?
    puts '4 language validation checks passed'
  else
    path = ARGV.first || File.join(__dir__, 'Sprak.json')
    data = JSON.parse(File.read(path))
    errors = validate_language(data)
    abort errors.join("\n") unless errors.empty?
    puts "#{data.fetch('tekster').size} language entries validated"
  end
end
