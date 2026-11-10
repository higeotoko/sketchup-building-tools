# frozen_string_literal: true

require_relative '../extension/sbr_architecture/section_depth'

class Numeric
  def mm
    self
  end
end

module Geom
  def self.linear_combination(wa, a, wb, b)
    a.zip(b).map { |x, y| wa * x + wb * y }
  end
end

clip = Higeotoko::SbrArchitecture::SectionDepth.new([1820, 0, 0], [1, 0, 0], 1200, {})
raise 'Far edge survived' if clip.segment([200, 0, 0], [500, 0, 0])
raise 'Near edge changed' unless clip.segment([700, 0, 0], [1200, 0, 0]) == [[700, 0, 0], [1200, 0, 0]]
segment = clip.segment([200, 1900, 0], [1100, 1000, 0])
raise 'Crossing edge ended outside the requested depth' unless segment == [[620, 1480, 0], [1100, 1000, 0]]
triangle = [[200, 0, 0], [1100, 900, 0], [1100, 0, 0]]
expected = [[620, 420, 0], [1100, 900, 0], [1100, 0, 0], [620, 0, 0]]
raise 'Crossing face was not cropped' unless clip.polygon(triangle) == expected

opposite = Higeotoko::SbrArchitecture::SectionDepth.new([0, 3030, 0], [0, -1, 0], 1200, {})
segment = opposite.segment([0, 3300, 0], [0, 5000, 0])
raise 'Reversing the eye did not reverse the retained side' unless segment.last[1].round(6) == 4230
puts 'Section depth clipping checks passed'
