@testable import Cairn
import Testing

@Suite("Tool categories")
struct ToolCategoryTests {
  @Test
  func `every tool is listed exactly once`() {
    let listed = ToolSelection.Category.allCases.flatMap(\.tools)
    #expect(listed.count == ToolSelection.allCases.count)
    #expect(Set(listed) == Set(ToolSelection.allCases))
  }

  @Test
  func `line of sight is the only titleless tool page`() {
    #expect(ToolSelection.lineOfSight.pageTitle.isEmpty)
    #expect(ToolSelection.allCases.filter { $0.pageTitle.isEmpty } == [.lineOfSight])
  }

  @Test
  func `every tool card has a subtitle`() {
    #expect(ToolSelection.allCases.allSatisfy { !$0.subtitle.isEmpty })
  }
}
