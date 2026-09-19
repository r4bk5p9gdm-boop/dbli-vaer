# Run from any directory: ruby validate_alert_templates.rb [path to markdown]

def validate_alert_templates(text)
  required = {
    'first-line template' => 'Det blir [Værtype]! [sted] [tid]',
    'second-line template' => '[Beskrivelse] [dag], kl. [TT] — [varighet]',
    'language table' => '| Nøkkel | Bokmål | Inntrøndersk | English |',
    'rain table' => '#### Regn',
    'snow table' => '#### Snø',
    'wind table' => '#### Vindkast (forenklet Beaufort-ordbok)'
  }
  required.each_with_object([]) do |(label, marker), errors|
    errors << "#{label}: mangler #{marker}" unless text.include?(marker)
  end
end

if __FILE__ == $PROGRAM_NAME
  path = ARGV.first || File.join(__dir__, 'VARSELTEKSTER.md')
  errors = validate_alert_templates(File.read(path))
  abort errors.join("\n") unless errors.empty?
  puts 'Alert template document validated'
end
