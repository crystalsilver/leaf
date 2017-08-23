import Core
import Foundation

/// Renders Leaf templates using the Leaf parser and serializer.
public final class Renderer {
    /// The tags available to this renderer.
    public let tags: [String: Tag]

    /// The renderer will use this to read files for
    /// tags that require it (such as #embed)
    public let fileReader: FileReader

    /// Create a new Leaf renderer.
    public init(tags: [String: Tag]? = nil, fileReader: FileReader) {
        self.tags = tags ?? defaultTags
        self.fileReader = fileReader
    }

    // ASTs only need to be parsed once
    private var _cachedASTs: [Int: [Syntax]] = [:]

    /// Renders the supplied template bytes into a view
    /// using the supplied context.
    public func render(template: Data, context: Context, on queue: DispatchQueue) throws -> Future<Data> {
        let hash = template.hashValue

        let ast: [Syntax]
        if let cached = _cachedASTs[hash] {
            ast = cached
        } else {
            let parser = Parser(data: template)
            do {
                ast = try parser.parse()
            } catch let error as ParserError {
                throw RenderError(source: error.source, reason: error.reason, error: error)
            }
            _cachedASTs[hash] = ast
        }

        do {
            let serializer = Serializer(ast: ast, renderer: self, context: context)
            return try serializer.serialize(on: queue)
        } catch let error as SerializerError {
            throw RenderError(source: error.source, reason: error.reason, error: error)
        } catch let error as TagError {
            throw RenderError(source: error.source, reason: error.reason, error: error)
        }
    }
}

// MARK: Convenience

extension Renderer {
    /// Loads the leaf template from the supplied path.
    public func render(path: String, context: Context, on queue: DispatchQueue) -> Future<Data> {
        let path = path.hasSuffix(".leaf") ? path : path + ".leaf"
        let promise = Promise(Data.self)

        fileReader.read(at: path).then(on: queue) { view in
            do {
                try self.render(template: view, context: context, on: queue).then(on: queue) { data in
                    promise.complete(data)
                }.catch(on: queue) { error in
                    promise.fail(error)
                }
            } catch var error as RenderError {
                error.path = path
                promise.fail(error)
            } catch {
                promise.fail(error)
            }
        }.catch(on: queue) { error in
            promise.fail(error)
        }

        return promise.future
    }

    /// Renders a string template and returns a string.
    public func render(_ view: String, context: Context, on queue: DispatchQueue) -> Future<String> {
        let promise = Promise(String.self)

        do {
            guard let data = view.data(using: .utf8) else {
                throw "could not convert string"
            }

            try render(template: data, context: context, on: queue).then(on: queue) { rendered in
                do {
                    guard let string = String(data: rendered, encoding: .utf8) else {
                        throw "could not convert data to string"
                    }

                    promise.complete(string)
                } catch {
                    promise.fail(error)
                }
            }.catch(on: queue) { error in
                promise.fail(error)
            }
        } catch {
            promise.fail(error)
        }

        return promise.future
    }
}
