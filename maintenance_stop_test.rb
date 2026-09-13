# Controlled dry run of the documented maintenance policy.
# Does not invoke Codex, change the schedule, or modify production status.
require 'json'

state = { 'continue' => true, 'noProgressCount' => 0 }
executed = []
events = []
tasks = [
  ['Kontroller Git-diff', -> { system('git', 'diff', '--check') ? :progress : :blocked }],
  ['Simulert forsøk uten fremdrift 1', -> { :idle }],
  ['Simulert forsøk uten fremdrift 2', -> { :idle }],
  ['SKAL IKKE KJØRES', -> { raise 'Stoppvernet sviktet' }]
]

events << 'START: continue=true'
tasks.each do |name, work|
  break unless state['continue']
  executed << name
  outcome = work.call
  case outcome
  when :progress
    state['noProgressCount'] = 0
  when :idle
    state['noProgressCount'] += 1
  when :blocked
    state['continue'] = false
  else
    raise "Unknown outcome: #{outcome}"
  end
  state['continue'] = false if state['noProgressCount'] >= 2
  events << "#{name}: #{outcome}, continue=#{state['continue']}"
end

raise 'Useful task failed' unless executed.size == 3
raise 'Expected automatic stop' unless state['continue'] == false
raise 'Expected two idle attempts' unless state['noProgressCount'] == 2
puts JSON.pretty_generate({
  scope: 'Controlled local policy test; not an end-to-end scheduler test',
  events: events,
  next_task_started: executed.include?('SKAL IKKE KJØRES'),
  production_status_modified: false,
  result: 'PASS'
})
