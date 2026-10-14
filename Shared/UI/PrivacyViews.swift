import SwiftUI

struct ExtractionConsentView: View {
    let scope: ExtractionConsent
    let allow: () -> Void
    let cancel: () -> Void
    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        MarginTitle(title: "让模型帮你整理", subtitle: "先确认这次内容的去向。")
                        PaperCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("接收服务").font(.caption).foregroundStyle(Notebook.secondaryInk)
                                Text(scope.host).font(.headline).textSelection(.enabled)
                                Text(scope.serviceURL).font(.caption).foregroundStyle(Notebook.secondaryInk).textSelection(.enabled)
                                Text("将发送原文（含图片识别出的文字）、参考日期、时区、你指定的日程类别，以及你设置的提示词。")
                                if scope.includesCalendarNames {
                                    Text("还会发送可写日历的名称，用于自动匹配日历。")
                                }
                                if scope.includesPlanning { Text("还会发送这次安排的目标、问答内容和待调整的方案。") }
                                if scope.includesAvailability { Text("还会发送本机计算的可用时间区间，用于避开已有安排。") }
                                Text("原始图片及已有事件的标题、地点和备注不会发送。API Key 仅用于向该接口认证。")
                                    .foregroundStyle(Notebook.secondaryInk)
                            }.font(.subheadline)
                        }
                        Text("这是你选择的第三方服务，其保存和处理内容的方式由服务提供方决定。请确认你愿意将这些内容交给该服务。")
                            .font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                        NavigationLink("阅读隐私政策") { LegalDocumentView() }.font(.subheadline)
                        Text("允许后，相同服务和发送范围不再重复询问。可在设置中撤销授权。")
                            .font(.caption).foregroundStyle(Notebook.secondaryInk)
                        Button(scope.includesPlanning ? "允许并继续" : "允许并提取", action: allow).buttonStyle(InkButtonStyle()).accessibilityIdentifier("allowExtraction")
                        Button("暂不发送", action: cancel).buttonStyle(InkButtonStyle(prominent: false)).accessibilityIdentifier("declineExtraction")
                    }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
            }.foregroundStyle(Notebook.ink)
                .navigationTitle("发送前确认").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel) } }
        }
    }
}

struct LegalDocumentView: View {
    var showsFontLicense = false
    private var content: String {
        guard let url = Bundle.main.url(forResource: showsFontLicense ? "OFL" : "PrivacyPolicy", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "无法打开说明。请联系 trlu1997@outlook.com。"
        }
        return text
    }
    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(content).font(.subheadline).textSelection(.enabled).lineSpacing(5)
                    if !showsFontLicense {
                        Link("在线隐私政策", destination: AppLegal.privacyURL)
                        Link("联系作者", destination: AppLegal.emailURL)
                    }
                }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity, alignment: .center)
            }
        }.foregroundStyle(Notebook.ink)
            .navigationTitle(showsFontLicense ? "字体许可" : "隐私政策").navigationBarTitleDisplayMode(.inline)
    }
}
