# frozen_string_literal: true

require_relative '../extension/sbr_architecture/section_placement'

placement = Higeotoko::SbrArchitecture::SectionPlacement
horizontal = placement.line([500, 900], [2700, 940])
raise 'A cut along X did not use a fixed Y coordinate' unless horizontal.to_a == [1, 900, [500, 900], [2700, 900]]
raise 'Arrow to positive Y should look from negative Y' unless placement.settings(horizontal, [500, 901]) == { side: 'y-', offset: 900 }
raise 'Arrow to negative Y should look from positive Y' unless placement.settings(horizontal, [500, -200]) == { side: 'y+', offset: 900 }
raise 'A click on the cut should not choose a direction' if placement.settings(horizontal, [500, 900.4])

vertical = placement.line([800, -250], [780, -3150])
raise 'A cut along Y did not use a fixed X coordinate' unless vertical.to_a == [0, 800, [800, -250], [800, -3150]]
raise 'Arrow to positive X should look from negative X' unless placement.settings(vertical, [900, 0]) == { side: 'x-', offset: 800 }
raise 'Arrow to negative X should look from positive X' unless placement.settings(vertical, [700, 0]) == { side: 'x+', offset: 800 }
raise 'Axis lock ignored the requested direction' unless placement.line([5, 6], [70, 12], 1).finish == [5, 12]
raise 'A coincident endpoint was accepted' if placement.line([5, 6], [5.1, 5.9])
raise 'Axis lock accepted a zero-length segment' if placement.line([5, 6], [70, 6], 1)

module Sketchup
  InputPoint = Class.new
end

view = Object.new
def view.invalidate; end
model = Struct.new(:tool, :view) do
  def select_tool(_)
    tool.deactivate(view)
  end
end.new(nil, view)
events = []
fixture = Class.new(placement) do
  def onMouseMove(_flags, x, y, _view)
    @cursor = [x, y]
  end

  def prompt; end
end
tool = fixture.new(model) { |data| events << data }
model.tool = tool
tool.onLButtonDown(0, 100, 500, view)
tool.onLButtonDown(0, 1000, 525, view)
tool.onLButtonDown(0, 500, 500, view)
raise 'Click on the line ended the tool' unless events.empty?
tool.onCancel(0, view)
tool.onLButtonDown(0, 101, 1900, view)
tool.onLButtonDown(0, 1010, 640, view)
raise 'Undoing the endpoint did not let the user change the axis' unless events == [{ side: 'x-', offset: 100 }]

model.tool = fixture.new(model) { |data| events << data }
model.tool.onCancel(0, view)
model.tool.deactivate(view)
raise 'Esc or tool deactivation sent multiple results' unless events.size == 2 && events.last.nil?
puts 'Section placement axes, arrows, rejected picks, rollback and tool cancellation passed'
