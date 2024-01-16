3D interactive globe built with Scene kit and swift. 

How the globe works:

  Scene (parent)
  
      (Camera Node child)
      
          -Camera actions executed on this child
          
      (Earth Node child)
      
          (14k Dot Nodes Children) - represent Land

The globe is rendered by analysizing the bytes on a 2d image representation of Earth. Pixel density and alpha value is used to dictate if a specific coordinate
contains land. If a point contains land the 2d coordinate is converted into a 3d coordinate based on the scene and a node is added to the earth node as a child.

How Gestures are handled: (Objective C)

2d position of a gesture is recoginzed -> Use Vector calculus to convert gesture to 3d coordinate -> Use Uber h3 indexing system to map coordinates to index
query database based on Uber h3 index at resolution 2. 

-> resolution is calculated based on Globe magnification.

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        let touchLocation = gesture.location(in: viewModel.sceneView)
        let hitTestResults = viewModel.sceneView.hitTest(touchLocation, options: nil)
            
        if hitTestResults.count >= 2 {
            viewModel.focusLocation = FocusLocation(x: touchLocation.x, y: touchLocation.y)
            let final = hitTestResults[1]
            let globeCoordinate = convertVectorToGlobeCoordinate(vector: final.localCoordinates)
            
            let index = globeCoordinate.h3CellIndex(resolution: 1)
            let hex = String(index, radix: 16, uppercase: true)
            let neighbors = globeCoordinate.h3Neighbors(resolution: 1, ringLevel: 1)
            var arr = [String]()
            for item in neighbors {
                arr.append(String(item, radix: 16, uppercase: true))
            }
            viewModel.handleGlobeTap(place: hex, neighbors: arr)
        }
    }
