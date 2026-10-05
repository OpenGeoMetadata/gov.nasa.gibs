# The smallest box covering a set of bounding boxes. Longitudes are treated as a circle, so maps
# spanning Palau to Maine get a box that crosses the antimeridian rather than one circling the globe,
# which would put the collection in every spatial search.
class Extent
  attr_reader :north, :south

  def initialize
    @intervals = []
  end

  # A box whose west is past its east crosses the antimeridian, and counts as its two halves
  def add(west, east, north, south)
    @intervals.concat(west > east ? [[west, 180.0], [-180.0, east]] : [[west, east]])
    @north = [@north, north].compact.max
    @south = [@south, south].compact.min
  end

  def empty?
    @intervals.empty?
  end

  # [west, east] of the narrowest span covering every box: the whole circle except the widest gap
  # between them. When west > east, the span crosses the antimeridian, as ENVELOPE allows.
  def longitudes
    spans = merged
    gaps = spans.each_cons(2).map { |(_, gap_start), (gap_end, _)| [gap_end - gap_start, gap_start, gap_end] }
    gaps << [spans.first[0] + 360 - spans.last[1], spans.last[1], spans.first[0]]
    _width, east, west = gaps.max_by(&:first)
    [west, east]
  end

  private

  # The intervals with overlapping ones combined, in west-to-east order
  def merged
    @intervals.sort.each_with_object([]) do |(west, east), spans|
      if spans.any? && west <= spans.last[1]
        spans.last[1] = [spans.last[1], east].max
      else
        spans << [west, east]
      end
    end
  end
end
