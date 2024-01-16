import Foundation
import SceneKit
import CoreImage
import SwiftUI
import MapKit
import Combine

public typealias GenericController = UIViewController
public typealias GenericColor = UIColor
public typealias GenericImage = UIImage

public class GlobeViewController: GenericController {
    var viewModel: GlobeViewModel

    private var worldMapImage: CGImage {
        guard let image = UIImage(named: "earth-dark")?.cgImage else {
            fatalError("E90")
        }
        return image
    }

    private lazy var imgData: CFData = {
        guard let imgData = worldMapImage.dataProvider?.data else { fatalError("Could not fetch data from world map image.") }
        return imgData
    }()

    private lazy var worldMapWidth: Int = {
        return worldMapImage.width
    }()

    var earthRadius: Double = 1.0
   
    public var dotSize: CGFloat = 0.005 {
        didSet {
            if dotSize != oldValue {
                setupDotGeometry()
            }
        }
    }
    
    public var enablesParticles: Bool = true {
        didSet {
            if enablesParticles {
                setupParticles()
            } else {
                viewModel.sceneView.scene?.rootNode.removeAllParticleSystems()
            }
        }
    }
    
    public var particles: SCNParticleSystem? {
        didSet {
            if let particles = particles {
                viewModel.sceneView.scene?.rootNode.removeAllParticleSystems()
                viewModel.sceneView.scene?.rootNode.addParticleSystem(particles)
            }
        }
    }
    
    public var earthColor: Color = .earthColor {
        didSet {
            if let earthNode = viewModel.earthNode {
                earthNode.geometry?.firstMaterial?.diffuse.contents = earthColor
                earthNode.geometry?.firstMaterial?.isDoubleSided = true
            }
        }
    }
    
    public var glowColor: Color = .earthGlow {
        didSet {
            if let earthNode = viewModel.earthNode {
                earthNode.geometry?.firstMaterial?.emission.contents = earthColor//glowColor
            }
        }
    }
    
    public var reflectionColor: Color = .earthReflection {
        didSet {
            if let earthNode = viewModel.earthNode {
                earthNode.geometry?.firstMaterial?.emission.contents = glowColor
            }
        }
    }

    public var glowShininess: CGFloat = 1.0 {
        didSet {
            if let earthNode = viewModel.earthNode {
                earthNode.geometry?.firstMaterial?.shininess = glowShininess
            }
        }
    }

    private var dotRadius: CGFloat {
        if dotSize > 0 {
             return dotSize
        }
        else {
            return 0.01 * CGFloat(earthRadius) / 1.0
        }
    }

    var dotCount = 80000
    weak var actionModel: ActionViewModel!
    private var anyCancellable: Set<AnyCancellable> = .init()
    
    init(popRoot: GlobeViewModel, action: ActionViewModel) {
        self.viewModel = popRoot
        self.actionModel = action
        super.init(nibName: nil, bundle: nil)
        
        actionModel.controller = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        anyCancellable.removeAll()
        
        if actionModel != nil {
            actionModel.controller = nil
        }
    }
    
    @objc func moveToLocation(lat: Double, long: Double) {
        if let map = viewModel.textureMap {
            let place = CLLocationCoordinate2D(latitude: lat, longitude: long)
            let newYorkDot = closestDotPosition(to: place, in: map)
        
            if let pos = map.first(where: { $0.x == newYorkDot.x && $0.y == newYorkDot.y }) {
                self.centerCameraOnDot(dotPosition: pos.position)
            }
        } else {
            let textureMap = generateTextureMap(dots: dotCount, sphereRadius: CGFloat(earthRadius))
            let place = CLLocationCoordinate2D(latitude: lat, longitude: long)
            let newYorkDot = closestDotPosition(to: place, in: textureMap)
        
            if let pos = textureMap.first(where: { $0.x == newYorkDot.x && $0.y == newYorkDot.y }) {
                self.centerCameraOnDot(dotPosition: pos.position)
            }
            viewModel.textureMap = textureMap
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        
        setupScene()

        setupParticles()
        
        setupCamera()
        setupGlobe()
        
        setupDotGeometry()
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        viewModel.sceneView.addGestureRecognizer(tapGesture)
    }
    
    private func setupScene() {
        let scene = SCNScene()
        viewModel.sceneView = SCNView(frame: view.frame)
    
        viewModel.sceneView.scene = scene
        viewModel.sceneView.showsStatistics = true
        viewModel.sceneView.backgroundColor = .black
        viewModel.sceneView.allowsCameraControl = true
        viewModel.sceneView.isUserInteractionEnabled = true
        
        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        viewModel.sceneView.addGestureRecognizer(doubleTapGesture)
        
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.minimumNumberOfTouches = 2
        viewModel.sceneView.addGestureRecognizer(panGesture)
        
        self.view.addSubview(viewModel.sceneView)
    }
    
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
    
    private func convertVectorToGlobeCoordinate(vector: SCNVector3) -> CLLocationCoordinate2D {
        let radius = Double(earthRadius)

        let theta = atan2(Double(vector.x), Double(vector.z))
        let phi = acos(Double(vector.y) / radius)

        let latitude = 90.0 - phi * (180.0 / .pi)
        let longitude = (theta * (180.0 / .pi)).truncatingRemainder(dividingBy: 360.0)
        
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    @objc private func handleDoubleTap(_ gestureRecognizer: UITapGestureRecognizer) {
        if let loc = viewModel.currentLocation {
            moveToLocation(lat: loc.lat, long: loc.long)
        }
    }
    
    @objc private func handlePan(_ gestureRecognizer: UIPanGestureRecognizer) { }
    
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        withAnimation {
            viewModel.option = 3
            viewModel.hideSearch.toggle()
        }
    }
        
    private func setupParticles() {
        guard let stars = SCNParticleSystem(named: "StarsParticles.scnp", inDirectory: nil) else { return }
        stars.isLightingEnabled = false
                
        if viewModel.sceneView != nil {
            viewModel.sceneView.scene?.rootNode.addParticleSystem(stars)
        }
    }
    
    private func setupCamera() {
        if viewModel.cameraNode == nil {
            self.viewModel.cameraNode = SCNNode()
            viewModel.cameraNode.camera = SCNCamera()
            viewModel.cameraNode.position = SCNVector3(x: 0, y: 0, z: 5)
            
            viewModel.sceneView.scene?.rootNode.addChildNode(viewModel.cameraNode)
        } else {
            viewModel.sceneView.scene?.rootNode.addChildNode(viewModel.cameraNode)
        }
    }

    private func setupGlobe() {
        if viewModel.earthNode == nil {
            self.viewModel.earthNode = EarthNode(radius: earthRadius, earthColor: earthColor, earthGlow: glowColor, earthReflection: reflectionColor)

            let interiorRadius: CGFloat = earthRadius * 0.9
            let interiorSphere = SCNSphere(radius: interiorRadius)
            let interiorNode = SCNNode(geometry: interiorSphere)
            interiorNode.geometry?.firstMaterial?.diffuse.contents = UIColor.black
            interiorNode.geometry?.firstMaterial?.isDoubleSided = true
            viewModel.earthNode.addChildNode(interiorNode)

            viewModel.sceneView.scene?.rootNode.addChildNode(viewModel.earthNode)
        } else {
            viewModel.sceneView.scene?.rootNode.addChildNode(viewModel.earthNode)
        }
    }
    
    private func setupDotGeometry() {
        if viewModel.textureMap == nil {
            self.viewModel.textureMap = generateTextureMap(dots: dotCount, sphereRadius: CGFloat(earthRadius))
        }

        if let textureMap = self.viewModel.textureMap {
            var newYork: CLLocationCoordinate2D?
            if let lat = viewModel.currentLocation?.lat, let long = viewModel.currentLocation?.long {
                newYork = CLLocationCoordinate2D(latitude: lat, longitude: long)
            }
            var newYorkDot: (x: Int, y: Int)? = nil
            if let newYork = newYork {
                newYorkDot = closestDotPosition(to: newYork, in: textureMap)
            }
    
            let threshold: CGFloat = 0.03
            
            let dotColor = GenericColor(white: 1, alpha: 1)
            let dotGeometry = SCNSphere(radius: dotRadius)
            dotGeometry.firstMaterial?.diffuse.contents = dotColor
            dotGeometry.firstMaterial?.lightingModel = SCNMaterial.LightingModel.constant
            
            let oceanColor = GenericColor(cgColor: UIColor.systemRed.cgColor)
            let oceanGeometry = SCNSphere(radius: dotRadius)
            oceanGeometry.firstMaterial?.diffuse.contents = oceanColor
            oceanGeometry.firstMaterial?.lightingModel = SCNMaterial.LightingModel.constant
            
            var positions = [SCNVector3]()
            var dotNodes = [SCNNode]()
            
            for i in 0...textureMap.count - 1 {
                let u = textureMap[i].x
                let v = textureMap[i].y
                
                let pixelColor = self.getPixelColor(x: Int(u), y: Int(v))
                var isHighlight = false
                if let dot = newYorkDot {
                    isHighlight = u == dot.x && v == dot.y
                }
                
                if (isHighlight) {
                    let lowerCircle = SCNTorus(ringRadius: dotRadius * 5, pipeRadius: dotRadius * 3)
                    lowerCircle.firstMaterial?.diffuse.contents = GenericColor(cgColor: UIColor.green.cgColor)
                    lowerCircle.firstMaterial?.lightingModel = SCNMaterial.LightingModel.constant
                    
                    let inner = SCNSphere(radius: dotRadius * 6)
                    inner.firstMaterial?.diffuse.contents = GenericColor(cgColor: UIColor.black.cgColor)
                    inner.firstMaterial?.lightingModel = SCNMaterial.LightingModel.constant

                    let dotNode = SCNNode(geometry: lowerCircle)
                    let child = SCNNode(geometry: inner)
                    
                    dotNode.eulerAngles = getEulerAngles(lat: viewModel.currentLocation?.lat ?? 0.0,
                                                         long: viewModel.currentLocation?.long ?? 0.0)
                    
                    let translation = SCNVector3(0.0, 0.01, 0.0)
                    child.position = translation
                    
                    dotNode.addChildNode(child)

                    dotNode.position = textureMap[i].position
                    positions.append(dotNode.position)
                    dotNodes.append(dotNode)
                    
                } else if (pixelColor.red < threshold && pixelColor.green < threshold && pixelColor.blue < threshold) {
                    let dotNode = SCNNode(geometry: dotGeometry)
                    dotNode.position = textureMap[i].position
                    positions.append(dotNode.position)
                    dotNodes.append(dotNode)
                }
            }
            
            DispatchQueue.main.async {
                let dotPositions = positions as NSArray
                let dotIndices = NSArray()
                let source = SCNGeometrySource(vertices: dotPositions as! [SCNVector3])
                let element = SCNGeometryElement(indices: dotIndices as! [Int32], primitiveType: .point)
                
                let pointCloud = SCNGeometry(sources: [source], elements: [element])
                
                let pointCloudNode = SCNNode(geometry: pointCloud)
                for dotNode in dotNodes {
                    pointCloudNode.addChildNode(dotNode)
                }
                self.viewModel.sceneView.scene?.rootNode.addChildNode(pointCloudNode)
            }
        }
    }
    
    func getEulerAngles(lat: Double, long: Double) -> SCNVector3 {
        let latRad = lat * .pi / 180.0
        let longRad = long * .pi / 180.0

        let rotationX = -latRad - 1.57

        let rotationY = longRad

        let rotationZ = 0.0

        return SCNVector3(rotationX, rotationY, rotationZ)
    }
    
    func centerCameraOnDot(dotPosition: SCNVector3) {
        if viewModel.sceneView != nil && viewModel.cameraNode != nil {
            let p = viewModel.sceneView.pointOfView?.transform
            if let p = p {
                viewModel.cameraNode.transform = p
            }
            viewModel.sceneView.pointOfView = viewModel.cameraNode
            
            let fixedDistance: Float = 5.0
            let newCameraPosition = dotPosition.normalized().scaled(to: fixedDistance)
            
            let moveAction = SCNAction.move(to: newCameraPosition, duration: 0.85)
            
            let constraint = SCNLookAtConstraint(target: viewModel.earthNode)
            constraint.isGimbalLockEnabled = true
            
            viewModel.sceneView.gestureRecognizers?.forEach { $0.isEnabled = false }
            
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 1.0
            
            self.viewModel.cameraNode.constraints = [constraint]
            self.viewModel.cameraNode.runAction(moveAction) {
                DispatchQueue.main.async {
                    self.viewModel.sceneView.gestureRecognizers?.forEach { $0.isEnabled = true }
                }
            }
            SCNTransaction.commit()
        }
    }
    func zoomIn(zoomIn: Bool) {
        if viewModel.sceneView != nil && viewModel.cameraNode != nil {
            let p = viewModel.sceneView.pointOfView?.transform
            if let p = p {
                viewModel.cameraNode.transform = p
            }
            viewModel.sceneView.pointOfView = viewModel.cameraNode
            
            let fixedDistance: Float = zoomIn ? 1.0 : 5.0
            let newCameraPosition = viewModel.cameraNode.position.normalized().scaled(to: fixedDistance)
            
            let moveAction = SCNAction.move(to: newCameraPosition, duration: 0.32)
            
            let constraint = SCNLookAtConstraint(target: viewModel.earthNode)
            constraint.isGimbalLockEnabled = true
            
            viewModel.sceneView.gestureRecognizers?.forEach { $0.isEnabled = false }
            
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 1.0
            
            self.viewModel.cameraNode.constraints = [constraint]
            self.viewModel.cameraNode.runAction(moveAction) {
                DispatchQueue.main.async {
                    self.viewModel.sceneView.gestureRecognizers?.forEach { $0.isEnabled = true }
                }
            }
            SCNTransaction.commit()
        }
    }
    
    typealias MapDot = (position: SCNVector3, x: Int, y: Int)
    
    private func generateTextureMap(dots: Int, sphereRadius: CGFloat) -> [MapDot] {

        let phi = Double.pi * (sqrt(5) - 1)
        var positions = [MapDot]()

        for i in 0..<dots {

            let y = 1.0 - (Double(i) / Double(dots - 1)) * 2.0 // y is 1 to -1
            let radiusY = sqrt(1 - y * y)
            let theta = phi * Double(i) // Golden angle increment
            
            let x = cos(theta) * radiusY
            let z = sin(theta) * radiusY

            let vector = SCNVector3(x: Float(sphereRadius * x),
                                    y: Float(sphereRadius * y),
                                    z: Float(sphereRadius * z))

            let pixel = equirectangularProjection(point: Point3D(x: x, y: y, z: z),
                                                  imageWidth: 2048,
                                                  imageHeight: 1024)

            let position = MapDot(position: vector, x: pixel.u, y: pixel.v)
            positions.append(position)
        }
        return positions
    }
    
    struct Point3D {
        let x: Double
        let y: Double
        let z: Double
    }

    struct Pixel {
        let u: Int
        let v: Int
    }

    func equirectangularProjection(point: Point3D, imageWidth: Int, imageHeight: Int) -> Pixel {
        let theta = asin(point.y)
        let phi = atan2(point.x, point.z)
        
        let u = Double(imageWidth) / (2.0 * .pi) * (phi + .pi)
        let v = Double(imageHeight) / .pi * (.pi / 2.0 - theta)
        
        return Pixel(u: Int(u), v: Int(v))
    }
    
    private func distanceBetweenPoints(x1: Int, y1: Int, x2: Int, y2: Int) -> Double {
        let dx = Double(x2 - x1)
        let dy = Double(y2 - y1)
        return sqrt(dx * dx + dy * dy)
    }
    
    private func closestDotPosition(to coordinate: CLLocationCoordinate2D, in positions: [(position: SCNVector3, x: Int, y: Int)]) -> (x: Int, y: Int) {
        let pixelPositionDouble = getEquirectangularProjectionPosition(for: coordinate)
        let pixelPosition = (x: Int(pixelPositionDouble.x), y: Int(pixelPositionDouble.y))

                
        let nearestDotPosition = positions.min { p1, p2 in
            distanceBetweenPoints(x1: pixelPosition.x, y1: pixelPosition.y, x2: p1.x, y2: p1.y) <
                distanceBetweenPoints(x1: pixelPosition.x, y1: pixelPosition.y, x2: p2.x, y2: p2.y)
        }
        
        return (x: nearestDotPosition?.x ?? 0, y: nearestDotPosition?.y ?? 0)
    }
    
    /// Convert a coordinate to an (x, y) coordinate on the world map image
    private func getEquirectangularProjectionPosition(
        for coordinate: CLLocationCoordinate2D
    ) -> CGPoint {
        let imageHeight = CGFloat(worldMapImage.height)
        let imageWidth = CGFloat(worldMapImage.width)

        // Normalize longitude to [0, 360). Longitude in MapKit is [-180, 180)
        let normalizedLong = coordinate.longitude + 180
        // Calculate x and y positions
        let xPosition = (normalizedLong / 360) * imageWidth
        // Note: Latitude starts from top, hence the `-` sign
        let yPosition = (-(coordinate.latitude - 90) / 180) * imageHeight
        return CGPoint(x: xPosition, y: yPosition)
    }

    private func getPixelColor(x: Int, y: Int) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let data: UnsafePointer<UInt8> = CFDataGetBytePtr(imgData)
        let pixelInfo: Int = ((worldMapWidth * y) + x) * 4

        let r = CGFloat(data[pixelInfo]) / CGFloat(255.0)
        let g = CGFloat(data[pixelInfo + 1]) / CGFloat(255.0)
        let b = CGFloat(data[pixelInfo + 2]) / CGFloat(255.0)
        let a = CGFloat(data[pixelInfo + 3]) / CGFloat(255.0)

        return (r, g, b, a)
    }
}

private extension Color {
    static var earthColor: Color {
        return Color(red: 0.227, green: 0.133, blue: 0.541)
    }
    
    static var earthGlow: Color {
        Color(red: 0.133, green: 0.0, blue: 0.22)
    }
    
    static var earthReflection: Color {
        Color(red: 0.227, green: 0.133, blue: 0.541)
    }
}

extension SCNVector3 {
    func length() -> Float {
        return sqrtf(x*x + y*y + z*z)
    }

    func normalized() -> SCNVector3 {
        let len = length()
        return SCNVector3(x: x/len, y: y/len, z: z/len)
    }

    func scaled(to length: Float) -> SCNVector3 {
        return SCNVector3(x: x * length, y: y * length, z: z * length)
    }

    func dot(_ v: SCNVector3) -> Float {
        return x * v.x + y * v.y + z * v.z
    }

    func cross(_ v: SCNVector3) -> SCNVector3 {
        return SCNVector3(y * v.z - z * v.y, z * v.x - x * v.z, x * v.y - y * v.x)
    }
}

extension SCNQuaternion {
    static func fromVectorRotate(from start: SCNVector3, to end: SCNVector3) -> SCNQuaternion {
        let c = start.cross(end)
        let d = start.dot(end)
        let s = sqrt((1 + d) * 2)
        let invs = 1 / s

        return SCNQuaternion(x: c.x * invs, y: c.y * invs, z: c.z * invs, w: s * 0.5)
    }
}
