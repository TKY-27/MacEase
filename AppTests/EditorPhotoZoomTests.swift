import XCTest

@testable import MacEase

extension MediaEditorModelTests {
    func testPhotoZoomStepsAndLevelReportRealPixels() async throws {
        let model = try await photoModel()
        XCTAssertEqual(model.photoZoomStep, .fit)
        XCTAssertNil(model.photoMagnification, "no level before the preview measured Fit")
        model.updatePhotoFitScale(0.25)
        XCTAssertEqual(model.photoZoomStep, .fit)
        XCTAssertEqual(model.photoMagnification, 0.25)
        XCTAssertEqual(PhotoZoomStep.percent(try XCTUnwrap(model.photoMagnification)), "25%")
        for (step, magnification) in [(PhotoZoomStep.actual, 1.0), (.double, 2), (.quadruple, 4)] {
            model.setPhotoZoomStep(step)
            XCTAssertEqual(model.photoZoomStep, step)
            XCTAssertEqual(try XCTUnwrap(model.photoMagnification), magnification, accuracy: 1e-9)
            XCTAssertEqual(step.title, PhotoZoomStep.percent(magnification))
        }
        XCTAssertEqual(PhotoZoomStep.allCases.map(\.title), ["Fit", "100%", "200%", "400%"])

        model.setPhotoZoomStep(.actual)
        model.setPhotoZoom(model.zoom * 1.5)
        XCTAssertNil(model.photoZoomStep, "an intermediate level selects nothing")
        XCTAssertEqual(PhotoZoomStep.percent(try XCTUnwrap(model.photoMagnification)), "150%")

        model.updatePhotoFitScale(0.5)
        XCTAssertEqual(try XCTUnwrap(model.photoMagnification), 1.5, accuracy: 1e-9, "resizing keeps the level")
        model.setPhotoZoomStep(.actual)
        model.updatePhotoFitScale(0.4)
        XCTAssertEqual(model.photoZoomStep, .actual)
        model.setPhotoZoomStep(.fit)
        model.updatePhotoFitScale(0.3)
        XCTAssertEqual(model.photoZoomStep, .fit, "Fit stays Fit")
    }

    func testPhotoZoomReachesActualSizeBelowFitForSmallImages() async throws {
        let model = try await photoModel()
        model.updatePhotoFitScale(3)
        model.setPhotoZoomStep(.actual)
        XCTAssertEqual(model.zoom, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(model.photoZoomStep, .actual)
        model.setPhotoZoom(0.01)
        XCTAssertEqual(model.photoZoomStep, .actual, "100% is the smallest level")
        model.setPhotoZoom(100)
        XCTAssertEqual(model.zoom, MediaEditorModel.photoZoomRange.upperBound)
        let large = try await photoModel()
        large.updatePhotoFitScale(0.1)
        large.setPhotoZoomStep(.quadruple)
        XCTAssertEqual(large.photoZoomStep, .quadruple, "400% stays reachable past 8× Fit")
        XCTAssertEqual(large.zoom, 40, accuracy: 1e-9)
        XCTAssertEqual(large.photoRenderDimension, 4096)
        model.updatePhotoFitScale(25)
        model.setPhotoZoomStep(.actual)
        XCTAssertEqual(model.photoRenderDimension, 80, "100% renders every source pixel")
    }
}
