# frozen_string_literal: true

%w[layout column_cuts slab_openings stairs].each do |name|
  require_relative "../extension/sbr_architecture/#{name}"
end

api = Higeotoko::SbrArchitecture
opening = { 'corners' => [[800, 1200], [4400, 2200]] }
outline = [[0, 0], [7000, 0], [7000, 4500], [0, 4500]]
rings = api::SlabOpenings.rings({ 'floor_openings' => [opening] }, outline)
raise 'The hole must preserve the rectangular footprint' unless rings.first == [[800, 1200], [4400, 1200], [4400, 2200], [800, 2200]]
raise 'Net slab area must subtract the opening' unless api::SlabOpenings.net_area({ 'points' => outline, 'floor_openings' => [opening] }) == 27_900_000

[{ 'floor_openings' => [opening, opening] }, { 'floor_openings' => [{ 'corners' => [[0, 200], [1000, 1000]] }] }].each do |bad|
  begin
    api::SlabOpenings.rings(bad, outline)
    raise 'An overlapping or boundary-touching hole was accepted'
  rescue ArgumentError
    # Invalid geometry must be rejected before creating the slab.
  end
end

params = api::Stairs.dimensions(opening.fetch('corners'), 'x+', 2940, 17).merge('risers' => 17)
raise 'Stair dimensions differ from the opening' unless params.values_at('run', 'width', 'going') == [3600, 1000, 223.75]
profile = api::Stairs.profile(params)
raise 'The stair must reach the top floor at the edge of the opening' unless profile[-2] == [3600, 2940]
raise 'The stair profile has duplicate points' unless profile.size == profile.uniq.size

winder = api::WinderStairs
rect = [[800, 1200], [4400, 2200]]
turns = winder::TURNS.keys
turns.product(turns).each do |lower, upper|
  next if lower == 'none' && upper == 'none'

  [2_940, 1_200].each do |height|
    data = api::Stairs.dimensions(rect, 'x+', height, 17, start_turn: lower, end_turn: upper)
    data.merge!('start_turn' => lower, 'end_turn' => upper)
    treads = winder.treads(data)
    raise 'A winder changed the riser count' unless treads.size == 17
    raise 'The straight run or winder has inverted vertices' unless treads.all? { |tread| api::ColumnCuts.signed_area(tread.outline) > 0 }
    raise 'Adjacent treads do not meet' unless treads.each_cons(2).all? { |a, b| a.exit.sort == b.entry.sort }
    raise 'A step extends outside the floor opening' unless treads.flat_map(&:outline).all? do |x, y|
      x.between?(0, 3600) && y.between?(0, 1000)
    end
    [[lower, treads.first.entry, 0], [upper, treads.last.exit, 3600]].each do |turn, seam, edge|
      axis, position = if turn == 'none'
                         [0, edge]
                       else
                         [1, turn.start_with?('left') ? 1000 : 0]
                       end
      raise 'Stair does not join the intended floor edge' unless seam.all? { |point| point[axis] == position }
    end

    shell = winder.shell(treads, height.to_f)
    raise 'A face contains duplicate vertices' unless shell.all? { |face| face.uniq.size == face.size }
    edges = shell.flat_map { |face| face.zip(face.rotate) }.tally
    raise "Open or inverted solid for #{[lower, upper, height]}" unless edges.all? do |(a, b), n|
      n == 1 && edges[[b, a]] == 1
    end
    raise 'The stair does not connect both floor levels' unless shell.flatten(1).map(&:last).minmax == [0, height]
  end
end

begin
  api::Stairs.dimensions([[0, 0], [1900, 1000]], 'x+', 2700, 15, start_turn: 'right3', end_turn: 'left2')
  raise 'Two winders were accepted without enough run for the middle'
rescue ArgumentError => error
  raise unless error.message.include?('納まりません')
end

class StairPlan
  attr_reader :lines, :texts

  def initialize
    @lines, @texts = [], []
  end

  def add_line(a, b)
    raise 'The stair plan contains a zero-length line' if a == b

    @lines << [a, b]
  end

  def add_text(text, point)
    @texts << [text, point]
  end
end

turned = api::Stairs.dimensions(rect, 'x+', 2940, 17, start_turn: 'right3', end_turn: 'left2')
turned.merge!('start_turn' => 'right3', 'end_turn' => 'left2')
below, above = StairPlan.new, StairPlan.new
winder.draw_plan(below, turned, ->(x, y) { [x, y] }, 7)
winder.draw_plan(above, turned, ->(x, y) { [x, y] }, 17)
raise 'The cut should show dashed lines above it' unless below.lines.size > above.lines.size
raise 'The ascent arrow label was lost' unless below.texts.map(&:first) == ['UP']
raise 'A turn produced no diagonal plan lines' unless below.lines.any? do |(x1, y1), (x2, y2)|
  (x2 - x1).abs > 150 && (y2 - y1).abs > 150
end

puts 'Straight stairs, all winder combinations, closed solid shells and floor opening clearance passed'
