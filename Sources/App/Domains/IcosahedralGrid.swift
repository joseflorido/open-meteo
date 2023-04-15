import Foundation

/**
 Icosahedral grid definition from ICON model
 
 https://www.dwd.de/DWD/forschung/nwv/fepub/icon_database_main.pdf
 https://esrl.noaa.gov/gsd/nim/references/geometric_properties_of_the_icosahedral_hexagonal_grid_on_the_two_sphere.pdf
 */
struct IcosahedralGrid {
    /// Earth radius used in ICON in meters
    let earthRadius = 6.371229e6
    
    /// Initial root division into `n` sections
    let n: Int
    
    /// `k` bisection steps
    let k: Int
    
    /// Average grid resolution in meters
    var gridResolutionMeters: Float {
        5050e3 / (Float(n) * powf(2, Float(k)))
    }
    
    /// Number of grid cells
    var count: Int {
        20 * n*n * Int(pow(4,Double(k)))
    }
    
    public init(n: Int, k: Int) {
        self.n = n
        self.k = k
    }
    
    func getCoordinates(gridpoint: Int) -> (latitude: Float, longitude: Float) {
        /// Edge length of one hexagonial triangle. 62.805°
        let hexgonLength: Float = 360 / 4 + sqrt(3)
        
        let pointsPerHexagonialTringle = count / 20
        /// 0-19 most outer tirangle index
        let hexgonalTriangleIndex = gridpoint / pointsPerHexagonialTringle
        /// 0-(n^2)
        let middleTriagleIndex = (gridpoint % pointsPerHexagonialTringle) / Int(pow(4,Double(k)))
        /// 0-(4^k) most inner triangle index
        let bisectecTriangleIndex = gridpoint % Int(pow(4,Double(k)))
        
        fatalError()
    }
    
    struct Triangle {
        let latitudeNorth: Float
        let latitudeSouth: Float
        let longitudeWest: Float
        let longitudeEast: Float
        
        var longitudeCenter: Float {
            (longitudeWest + longitudeEast) / 2
        }
        var latitudeCenter: Float {
            (latitudeNorth + latitudeSouth) / 2
        }
        
        /// divide Triangle by 3 ( = 9 new triangles)
        func divide3(n: Int) -> Triangle {
            let dLon = (longitudeEast - longitudeWest) / 3
            let dLat = (latitudeNorth - latitudeSouth) / 3
            if n == 0 {
                return Triangle(latitudeNorth: latitudeNorth, latitudeSouth: latitudeNorth - dLat, longitudeWest: longitudeWest, longitudeEast: longitudeEast)
            }
            fatalError()
        }
        
        /// divide Triangle by 2 ( = 4 new triangles)
        func divide2(n: Int) -> Triangle {
            let dLon = (longitudeEast - longitudeWest) / 2
            let dLat = (latitudeNorth - latitudeSouth) / 2
            if n == 0 {
                return Triangle(latitudeNorth: latitudeNorth, latitudeSouth: latitudeNorth - dLat, longitudeWest: longitudeWest, longitudeEast: longitudeEast)
            }
            if n == 1 {
                return Triangle(latitudeNorth: latitudeNorth - dLat, latitudeSouth: latitudeSouth, longitudeWest: longitudeWest, longitudeEast: longitudeWest + dLon)
            }
            fatalError()
        }
        
        var center: (latitude: Float, longitude: Float) {
            return (latitudeCenter, longitudeCenter)
        }
    }
    
    /**
     t = 0..<20 outer tirangle
     n = innter triangle .. e.g. 0..<9
     k = seq 0..<4
     */
    func p(t_: Int, n_: Int, k_: [Int]) -> Triangle {
        var triangle = Triangle(latitudeNorth: 90, latitudeSouth: 27.195, longitudeWest: 36, longitudeEast: 36+72)
        
        triangle = triangle.divide3(n: t_)
        triangle = triangle.divide2(n: n_)
        for k in k_ {
            triangle = triangle.divide2(n: k)
        }
        return triangle
    }
    
    func findPoint(latitude: Float, longitude: Float) -> Int {
        let verticies = getVertices()
        print(verticies)
        
        // Define the indices for the 20 triangles of the icosahedron
        let triangles: [[Int]] = [
            [ 0, 1, 2 ],  [ 0, 2, 3 ],  [ 0, 3, 4 ],  [ 0, 4, 5 ],   [ 0, 5, 1 ],
            [ 6, 2, 1 ],  [ 7, 3, 2 ],  [ 8, 4, 3 ],  [ 9, 5, 4 ],   [ 10, 1, 5 ],
            [ 2, 6, 7 ],  [ 3, 7, 8 ],  [ 4, 8, 9 ],  [ 5, 9, 10 ],  [ 1, 10, 6 ],
            [ 11, 7, 6 ], [ 11, 8, 7 ], [ 11, 9, 8 ], [ 11, 10, 9 ], [ 11, 6, 10 ]
        ]
        
        let point = Vector3.from(latitude: latitude, longitude: longitude)
        
        print(Vector3.from(latitude: -27.195, longitude: 0))
        
        // Compute the sub-triangle index and vertex indices for the point
        var subTriangleIndex: Int = -1
        var vertexIndices: [Int] = []
        for i in 0..<20 {

            // Compute the barycentric coordinates of the point in the sub-triangle
            let barycentric = getBarycentricCoordinates(point: point, v0: verticies[triangles[i][0]], v1: verticies[triangles[i][1]], v2: verticies[triangles[i][2]])
            print(barycentric)

            // Check if the point is inside the sub-triangle
            if barycentric.x >= 0.0 && barycentric.y >= 0.0 && barycentric.z >= 0.0 {
                return i
                subTriangleIndex = i
                vertexIndices = [i * 3, i * 3 + 1, i * 3 + 2]
                break
            }
        }
        
        fatalError()
    }
    
    func getVertices() -> [Vector3] {
        /*let phi = (1.0 + sqrt(5.0)) / 2.0
        return [
            // Group 1
            Vector3(x: 0.0, y: 1.0, z: phi),
            Vector3(x: 0.0, y: 1.0, z: -phi),
            Vector3(x: 0.0, y: -1.0, z: phi),
            Vector3(x: 0.0, y: -1.0, z: -phi),
            Vector3(x: phi, y: 0.0, z: 1.0),
            
            // Group 2
            Vector3(x: phi, y: 0.0, z: -1.0),
            Vector3(x: -phi, y: 0.0, z: 1.0),
            Vector3(x: -phi, y: 0.0, z: -1.0),
            Vector3(x: 1.0, y: phi, z: 0.0),
            
            // Group 3
            Vector3(x: 1.0, y: -phi, z: 0.0),
            Vector3(x: -1.0, y: phi, z: 0.0),
            Vector3(x: -1.0, y: -phi, z: 0.0)
        ]*/
        
        let pi_5 = Double.pi * 0.2
        let z_w = 2.0 * acos(1.0 / (2.0 * sin(pi_5)))

        var vertices = [Vector3](repeating: Vector3(x: 0.0, y: 0.0, z: 0), count: 12)
        // set poles first - it is simple
        vertices[0] = Vector3(x: 0.0, y: 0.0, z: 1.0)
        vertices[11] = Vector3(x: 0.0, y: 0.0, z: -1.0)

        // now set the vertices on the two latitude rings
        var i_mdist = Array(repeating: 0, count: 10)
        for j in 1..<11 {
          if j % 2 == 0 {
            i_mdist[j / 2 + 4] = -1 + (j - 1) - 10 * ((j - 1) / 7)
          } else {
            i_mdist[(j + 1) / 2 - 1] = -1 + (j - 1) - 10 * ((j - 1) / 7)
          }
        }

        for j in 1..<11 {
          // toggle the hemisphere
          let i_msgn = (j >= 6) ? -1.0 : 1.0
          // compute the meridian angle for the base vertex.
          let z_rlon = (1.0 + Double(i_mdist[j - 1])) * pi_5
          // now initialize the coordinates
          vertices[j] = Vector3(x: sin(z_w) * cos(z_rlon), y: sin(z_w) * sin(z_rlon), z: cos(z_w) * i_msgn)
        }
        return vertices
    }
}


// Define a Vector3 struct to represent 3D vectors
struct Vector3 {
    var x: Double
    var y: Double
    var z: Double
    
    static func from(latitude: Float, longitude: Float) -> Vector3 {
        let latRad: Double = Double(latitude) * Double.pi / 180.0
        let lonRad: Double = Double(longitude) * Double.pi / 180.0
        // Compute the Cartesian coordinates of the point on the sphere
        let x: Double = cos(latRad) * cos(lonRad)
        let y: Double = cos(latRad) * sin(lonRad)
        let z: Double = sin(latRad)
        
        return Vector3(x: x, y: y, z: z)
    }
    
    func subtract(_ other: Vector3) -> Vector3 {
        return Vector3(x: self.x - other.x, y: self.y - other.y, z: self.z - other.z)
    }
    
    func dot(_ other: Vector3) -> Double {
        return self.x * other.x + self.y * other.y + self.z * other.z
    }
}

func getBarycentricCoordinates(point: Vector3, v0: Vector3, v1: Vector3, v2: Vector3) -> Vector3 {
    let edge1 = v1.subtract(v0)
    let edge2 = v2.subtract(v0)
    let vp = point.subtract(v0)

    let dot00 = edge1.dot(edge1)
    let dot01 = edge1.dot(edge2)
    let dot02 = edge1.dot(vp)
    let dot11 = edge2.dot(edge2)
    let dot12 = edge2.dot(vp)

    let denom = dot00 * dot11 - dot01 * dot01
    let v = (dot11 * dot02 - dot01 * dot12) / denom
    let w = (dot00 * dot12 - dot01 * dot02) / denom
    let u = 1 - v - w

    return Vector3(x: u, y: v, z: w)
}