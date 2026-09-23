# Run from any directory: ruby validate_alert_templates.rb [path to markdown]

def validate_alert_templates(text)
  errors = []
  common = text.split(/^# Regn\s*$/, 2).first
  {
    'felles pushmal' => '### Push — første linje',
    'værtypenavn og nå-tekst' => '### Værtypenavn og nå-tekst',
    'tidskategorier' => '### Tid i første linje',
    'rullerende Hjem-mal' => '### Hjem — rullerende varsel',
    'usikker Hjem-mal' => '| Usikkert |',
    'nåstatus-mal' => '| Pågår nå |'
  }.each do |label, marker|
    errors << "#{label}: mangler #{marker}" unless common.include?(marker)
  end

  types = %w[Regn Snø Vindkast Duggfall Frost Sol Temperatur]
  types.each_with_index do |type, index|
    next_type = types[index + 1]
    section = text.split(/^# #{Regexp.escape(type)}\s*$/, 2)[1]
    if section.nil?
      errors << "værtype: mangler # #{type}"
      next
    end
    section = section.split(/^# #{Regexp.escape(next_type)}\s*$/, 2).first if next_type
    %w[Push-varsel Hjem\ —\ rullerende\ varsel Watch\ og\ CarPlay-widget].each do |surface|
      errors << "#{type}: mangler #{surface}" unless section.include?("## #{surface}")
    end
    errors << "#{type}: mangler språk-kolonner" unless section.include?('| Bokmål | Inntrøndersk |')
  end
  errors
end

if __FILE__ == $PROGRAM_NAME
  path = ARGV.first || File.join(__dir__, 'VARSELTEKSTER.md')
  errors = validate_alert_templates(File.read(path))
  abort errors.join("\n") unless errors.empty?
  puts 'Alert template document validated'
end
