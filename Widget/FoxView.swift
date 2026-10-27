import SwiftUI

/// 像素小狐狸。素材 50px 上下，放大必须关插值，不然糊成一团。
struct FoxView: View {
    let pose: String
    var size: CGFloat = 56

    var body: some View {
        let img = UIImage(named: "fox_\(pose)") ?? UIImage(named: "fox_idle")
        if let img {
            Image(uiImage: img)
                .resizable()
                .interpolation(.none)
                .antialiased(false)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}
