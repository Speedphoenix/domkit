package domkit;
import haxe.macro.Type;
import haxe.macro.Expr;
using haxe.macro.Tools;

class MetaError {
	public var message : String;
	public var position : Position;
	public function new(msg,pos) {
		this.message = msg;
		this.position = pos;
	}
}

enum ParserMode {
	PNone;
	PAuto;
}

class MetaComponent extends Component<Dynamic,Dynamic> {

	public var baseType : ComplexType;
	public var parserType : ComplexType;
	public var setExprs : Map<String, Expr> = new Map();
	var parser : CssValue.ValueParser;
	var classType : ClassType;
	var baseClass : ClassType;
	var constructorPath : Array<String>;
	var constructorArgs : Array<{ type : ComplexType, name : String, opt : Bool }>;

	public function new( t : Type, fields : Array<Field> ) {
		classType = switch( t ) {
		case TInst(c, _): c.get();
		default: error("Invalid type",haxe.macro.Context.currentPos());
		}

		var c = classType;
		var name = getCompName(c);
		if( name == null ) error("Missing :uiComp", c.pos);

		var ccur = c;
		var metaParent = null;
		while( true ) {
			if( ccur.superClass == null ) break;
			var csup = ccur.superClass.t.get();
			var cname = getCompName(csup);
			if( cname != null ) {
				metaParent = @:privateAccess try Macros.loadComponent(cname,0,0) catch( e : Error ) null;
				if( metaParent == null ) error("Missing super component registration "+cname, c.pos);
				break;
			}
			ccur = csup;
		}
		super(name,null,metaParent);

		initParser(c);
		if( metaParent == null ) {
			addHandler("class", parser.parseArray.bind(parser.parseIdent), null, macro : String);
			addHandler("id", parser.parseIdent, null, macro : String);
		}

		var baseT = t;
		for( i in c.interfaces )
			if( i.t.toString() == "domkit.ComponentDecl" )
				baseT = i.params[0];
		baseClass = switch( baseT.follow() ) { case TInst(c,_): c.get(); default: throw "assert"; };
		if( baseT != t )
			baseClass.meta.add(":uiComp",[{ expr : EConst(CString(name)), pos : c.pos }], c.pos);
		baseType = baseT.toComplexType();

		var fconstr = null;
		for( f in fields ) {
			for( m in f.meta )
				if( m.name == ":p" ) {
					defineField(f, m);
					break;
				}
			if( f.name == "new" && fconstr == null )
				fconstr = f;
			if( f.name == "create" && f.access.indexOf(AStatic) < 0 )
				fconstr = f;
		}
		initConstructor(fconstr);
	}

	public function getConstructorArgs() {
		if( constructorArgs != null )
			return constructorArgs;
		var p = Std.instance(parent, MetaComponent);
		if( p == null )
			return null;
		return p.getConstructorArgs();
	}

	function initConstructor( f : Field ) {
		if( f != null && f.name == "create" ) {
			var classPath = makeTypePath(classType);
			constructorPath = classPath.concat(["create"]);
		} else {
			constructorPath = switch( baseType ) {
			case TPath(p):
				var path = p.pack.copy();
				path.push(p.name);
				if( p.sub != null ) path.push(p.sub);
				path.push("new");
				path;
			default: throw "assert";
			}
		}

		if( f == null ) return;

		switch( f.kind ) {
		case FFun(f):
			var args = f.args.copy();
			args.pop(); // parent
			constructorArgs = args;
		default:
			error("Create method is not a function", f.pos);
		}
	}

	function initParser( c : ClassType ) {
		var pdef = c.meta.extract(":parser")[0];
		if( pdef == null ) {
			if( parent != null ) {
				var parent = cast(parent,MetaComponent);
				parserType = parent.parserType;
				parser = parent.parser;
			} else {
				parserType = macro : domkit.CssValue.ValueParser;
				parser = new domkit.CssValue.ValueParser();
			}
			return;
		}
		if( pdef.params.length == 0 )
			error("Invalid parser definition", pdef.pos);
		var e = pdef.params[0];
		var path = [];
		while( true ) {
			switch( e.expr ) {
			case EField(e2, field):
				path.unshift(field);
				e = e2;
			case EConst(CIdent(i)):
				path.unshift(i);
				break;
			default:
				error("Invalid parser definition", e.pos);
			}
		}
		var name = path.pop();
		inline function isUpper(str:String) return str.charCodeAt(0) >= 'A'.code && str.charCodeAt(0) <= 'Z'.code;
		var subType = path.length > 0 && isUpper(path[path.length - 1]) ? path.pop() : null;
		parserType = TPath({ pack : path, name : subType == null ? name : subType, sub : subType == null ? null : name });

		var clPath = path.length == 0 ? name : path.join(".")+"."+name;
		var cl = std.Type.resolveClass(clPath);
		if( cl == null )
			error("Class "+clPath+" has not been compiled in macros", pdef.pos);
		parser = std.Type.createInstance(cl,[]);
	}

	function defineField( f : Field, pm : MetadataEntry ) {
		var defExpr = null;
		var t = switch( f.kind ) {
		case FVar(t, def), FProp(_, _, t, def): defExpr = def; t;
		default: return;
		}
		var tt = haxe.macro.Context.resolveType(t, f.pos).follow();
		t = tt.toComplexType();

		var prop = null;
		var parserMode = PNone;

		if( pm.params.length > 0 )
			switch( pm.params[0].expr ) {
			case EConst(CIdent("none")):
				parserMode = PNone;
			case EConst(CIdent("auto")):
				parserMode = PAuto;
			case EConst(CIdent(name)):
				var fname = "parse"+name.charAt(0).toUpperCase()+name.substr(1);
				var meth = Reflect.field(this.parser,fname);
				if( meth == null )
					error(parserType.toString()+" has no field "+fname, pm.params[0].pos);
				prop = {
					def : null,
					expr : macro (parser.$fname : domkit.CssValue -> $t),
					value : function(css:CssValue) : Dynamic {
						return Reflect.callMethod(this.parser,meth,[css]);
					}
				};
			default:
			}

		if( prop == null ) {
			prop = parserFromType(tt, f.pos, parserMode);
			if( prop == null ) error("Unsupported type "+t.toString()+", use custom parser", f.pos);
		} else {
			var pdef = parserFromType(tt, f.pos, parserMode);
			if( pdef != null ) prop.def = pdef.def;
		}

		switch( defExpr ) {
		case null:
		case { expr : EConst(c), pos : pos }:
			prop.def = defExpr;
		default:
			error("Invalid default expr", f.pos);
		}

		var h = addHandler(fieldToProp(f.name), prop.value, prop.def, t);
		h.position = f.pos;
		h.fieldName = f.name;
		h.parserExpr = prop.expr;
	}

	function fieldToProp( name : String ) {
		if( name.toUpperCase() == name )
			return name.toLowerCase();
		var out = new StringBuf();
		for( i in 0...name.length ) {
			var c = name.charCodeAt(i);
			if( c >= "A".code && c <= "Z".code ) {
				if( i > 0 ) out.addChar("-".code);
				out.addChar(c - "A".code + "a".code);
			} else
				out.addChar(c);
		}
		return out.toString().split("_").join("-");
	}

	function makeTypePath( t : BaseType ) {
		var path = t.module.split(".");
		if( t.name != path[path.length-1] ) path.push(t.name);
		return path;
	}

	function makeTypeExpr( t : BaseType, pos : Position ) {
		var path = makeTypePath(t);
		return haxe.macro.MacroStringTools.toFieldExpr(path);
	}

	function parserFromType( t : Type, pos : Position, mode : ParserMode ) : { expr : Expr, value : CssValue -> Dynamic, def : Expr } {
		switch( t ) {
		case TAbstract(a,params):
			switch( a.toString() ) {
			case "Int": return { expr : macro parser.parseInt, value : parser.parseInt, def : macro 0 };
			case "Float": return { expr : macro parser.parseFloat, value : parser.parseFloat, def : macro 0. };
			case "Bool": return { expr : macro parser.parseBool, value : parser.parseBool, def : macro false };
			case "Null":
				var p = parserFromType(params[0],pos,mode);
				if( p != null && p.def != null ) {
					switch( mode ) {
					case PNone:
						p.expr = macro parser.parseNone.bind(${p.expr});
						p.value = parser.parseNone.bind(p.value);
					case PAuto:
						p.expr = macro parser.parseAuto.bind(${p.expr});
						p.value = parser.parseAuto.bind(p.value);
					}
				}
				return p;
			default:
			}
		case TInst(c,_):
			switch( c.toString() ) {
			case "String":
				return  { expr : macro parser.parseString, value : parser.parseString, def : null };
			default:
			}
		case TEnum(en,_):
			var idents = [for( n in en.get().names ) n.toLowerCase()];
			var enexpr = makeTypeExpr(en.get(), pos);
			return {
				expr : macro parser.makeEnumParser($enexpr),
				value : function(css:CssValue) {
					return switch( css ) {
					case VIdent(i) if( idents.indexOf(i) >= 0 ): true;
					case VIdent(v): parser.invalidProp(v+" should be "+idents.join("|"));
					default: parser.invalidProp();
					}
				},
				def : null,
			};
		default:
		}
		return null;
	}

	function getCompName( c : ClassType ) {
		var name = c.meta.extract(":uiComp")[0];
		if( name == null ) return null;
		if( name.params.length == 0 ) error("Invalid :uiComp", name.pos);
		return switch( name.params[0].expr ) {
		case EConst(CString(name)): name;
		default: error("Invalid :uiComp", name.pos);
		}
	}

	function error( msg : String, pos : Position ) : Dynamic {
		throw new MetaError(msg, pos);
	}

	static function runtimeName( name : String ) {
		return "Comp"+name.charAt(0).toUpperCase()+name.substr(1);
	}

	static function setPosRec( e : haxe.macro.Expr, p : Position ) {
		e.pos = p;
		haxe.macro.ExprTools.iter(e, function(e) setPosRec(e,p));
	}

	public function getModulePath() {
		return classType.module;
	}

	public function buildRuntimeComponent( componentsType ) {
		var cname = runtimeName(name);
		var parentExpr;
		if( parent == null )
			parentExpr = macro null;
		else {
			var parentName = runtimeName(parent.name);
			parentExpr = macro @:privateAccess domkit.$parentName.inst;
		}

		var path;
		var setters = new Map();
		for( f in classType.statics.get() ) {
			if( !f.kind.match(FMethod(_)) )
				continue;
			if( StringTools.startsWith(f.name,"set_") )
				setters.set(fieldToProp(f.name.substr(4)), true);
		}

		var classPath = makeTypePath(classType);
		var newExpr = haxe.macro.MacroStringTools.toFieldExpr(constructorPath, classType.pos);
		var cargs = getConstructorArgs();
		if( cargs.length == 0 )
			newExpr = macro function(_,parent) return ($newExpr)(parent);
		else {
			var eargs = [];
			for( i in 0...cargs.length )
				eargs.push(macro args[$v{i}]);
			eargs.push(macro parent);
			newExpr = macro function(args,parent) return ($newExpr)($a{eargs});
		}

		var handlers = [];
		for( i in 0...propsHandler.length ) {
			var h = propsHandler[i];
			if( h == null || h.position == null ) continue;
			var p = @:privateAccess Property.ALL[i];
			if( parent != null && parent.propsHandler[i] == h && !setters.exists(p.name) ) continue;
			var ptype = h.type;
			var fname = h.fieldName;
			var set = setters.exists(p.name) ? haxe.macro.MacroStringTools.toFieldExpr(classPath.concat(["set_"+fname])) : macro function(o:$baseType,v:$ptype) o.$fname = v;
			var def = h.defaultValue == null ? macro null : h.defaultValue;
			var expr = macro addHandler($v{p.name},@:privateAccess ${h.parserExpr},($def : $ptype),@:privateAccess $set);
			setPosRec(expr,h.position);
			setExprs.set(p.name, set);
			handlers.push(expr);
		}

		var parserClass = switch( parserType ) {
		case TPath(t): t;
		default: throw "assert";
		}
		var fields = (macro class {
			var parser : $parserType;
			function new() {
				super($v{this.name},@:privateAccess $newExpr,$parentExpr);
				parser = new $parserClass();
				$b{handlers};
			}
			static var inst = new domkit.$cname();
		}).fields;

		var td : TypeDefinition = {
			pos : classType.pos,
			pack : ["domkit"],
			name : cname,
			kind : TDClass({ pack : ["domkit"], name : "Component", params : [TPType(componentsType),TPType(baseType)] }),
			fields : fields,
		};
		return td;
	}

	public function getRuntimeComponentType() {
		var name = runtimeName(name);
		return macro : domkit.$name;
	}

}