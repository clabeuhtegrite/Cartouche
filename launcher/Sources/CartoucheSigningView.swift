import SwiftUI
import UniformTypeIdentifiers

@available(iOS 17.0, *)
struct CartoucheSigningView: View {
    @ObservedObject private var setup = CartoucheSetup.shared
    @State private var certificate: Data?
    @State private var profile: Data?
    @State private var password = ""
    @State private var choosingFile = false
    @State private var choosingCertificate = true
    @State private var fileProblem: String?

    var body: some View {
        Form {
            Section {
                Text(CartoucheText.signingHow)
                Button(certificate == nil ? CartoucheText.signingChooseCertificate : CartoucheText.signingCertificateChosen) {
                    choosingCertificate = true
                    choosingFile = true
                }
                Button(profile == nil ? CartoucheText.signingChooseProfile : CartoucheText.signingProfileChosen) {
                    choosingCertificate = false
                    choosingFile = true
                }
                SecureField(CartoucheText.signingPassword, text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(CartoucheText.signingUse) {
                    guard let certificate, let profile else { return }
                    Task {
                        await setup.importSigning(certificate: certificate, password: password, profile: profile)
                        password = ""
                    }
                }
                .disabled(certificate == nil || profile == nil || setup.isImportingSigning)
                if setup.isImportingSigning { ProgressView(CartoucheText.setupCertificateChecking) }
                if let problem = fileProblem ?? setup.signingProblem {
                    Text(problem).foregroundStyle(.red)
                } else if setup.usesImportedSigning && setup.certificateWorks == true {
                    Label(CartoucheText.setupCertificateDone, systemImage: "checkmark.shield")
                }
            } footer: {
                Text(CartoucheText.signingReinstall)
            }
        }
        .navigationTitle(CartoucheText.signingTitle)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: fileTypes) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 4 * 1024 * 1024 else {
                    throw CartoucheImportedSigning.ImportError(message: CartoucheText.signingInvalidFile)
                }
                let data = try Data(contentsOf: url)
                if choosingCertificate { certificate = data } else { profile = data }
                fileProblem = nil
            } catch { fileProblem = error.localizedDescription }
        }
    }

    private var fileTypes: [UTType] {
        [UTType(filenameExtension: choosingCertificate ? "p12" : "mobileprovision") ?? .data, .data]
    }
}
