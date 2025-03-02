SuperStrict

Import brl.Max2D
Import SDL.SDLGraphics
Import brl.Threads
?Not opengles
Import pub.glew
Import Pub.OpenGL
?opengles
Import Pub.OpenGLES
?

Private
Global glewIsInit:Int

Struct Rect
	Method New (X:Int, Y:Int, width:Int, height:Int)
		Self.X = X
		Self.Y = Y
		Self.width = width
		Self.height = height
	EndMethod
	
	Field X:Int, Y:Int
	Field width:Int, height:Int
EndStruct

'Const GLMAX2D_USE_LEGACY = False
Global _driver:TGL2Max2DDriver
Global _BackbufferRenderImageFrame:TGL2SDLRenderImageFrame
Global _CurrentRenderImageFrame:TGL2SDLRenderImageFrame
Global _GLScissor_BMaxViewport:Rect = New Rect

'Naughty!
Const GL_BGR:Int = $80E0
Const GL_BGRA:Int = $80E1
Const GL_CLAMP_TO_EDGE:Int = $812F
Const GL_CLAMP_TO_BORDER:Int = $812D

Global ix:Float, iy:Float, jx:Float, jy:Float
Global color4ub:Byte[4]

Global state_blend:Int
Global state_boundtex:Int
Global state_texenabled:Int

Function BindTex( name:Int )
	If name = state_boundtex Return
	glBindTexture( GL_TEXTURE_2D, name )
	state_boundtex = name
End Function

Function EnableTex( name:Int )
	BindTex( name )
	If state_texenabled Return
	glEnable( GL_TEXTURE_2D )
	state_texenabled = True
End Function

Function DisableTex()
	BindTex( 0 )
	If Not state_texenabled Return
	glDisable( GL_TEXTURE_2D )
	state_texenabled = False
End Function

Function Pow2Size:Int( n:Int )
	Local t:Int = 1
	While t < n
		t :* 2
	Wend
	Return t
End Function

Global dead_texs:TDynamicArray = New TDynamicArray(32)
Global dead_tex_seq:Int

'Enqueues a texture for deletion, to prevent release textures on wrong thread.
Function DeleteTex( name:Int,seq:Int )
	If seq<>dead_tex_seq Return
	
	dead_texs.AddLast(name)
End Function

Function CreateTex:Int( width:Int,height:Int,flags:Int,pixmap:TPixmap )
	If pixmap.dds_fmt<>0 Return pixmap.tex_name ' if dds texture already exists

	'alloc new tex
	Local name:Int
	glGenTextures( 1, Varptr name )

	'flush dead texs
	If dead_tex_seq=GraphicsSeq
		Local n:Int = dead_texs.RemoveLast()
		While n <> $FFFFFFFF
			glDeleteTextures(1, Varptr n)
			n = dead_texs.RemoveLast()
		Wend
	EndIf

	dead_tex_seq = GraphicsSeq

	'bind new tex
	BindTex( name )

	'set texture parameters
	glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE )
	glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE )

	If flags & FILTEREDIMAGE
		glTexParameteri GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR
		If flags & MIPMAPPEDIMAGE
			glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR )
		Else
			glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR )
		EndIf
	Else
		glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST )
		If flags & MIPMAPPEDIMAGE
			glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST_MIPMAP_NEAREST )
		Else
			glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST )
		EndIf
	EndIf

	Local mip_level:Int
	Repeat
		glTexImage2D( GL_TEXTURE_2D, mip_level, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, Null )
		If Not ( flags & MIPMAPPEDIMAGE ) Exit
		If width = 1 And height = 1 Exit
		If width > 1 width :/ 2
		If height > 1 height :/ 2
		mip_level :+ 1
	Forever

	Return name
End Function

'NOTE: Assumes a bound texture.
Function UploadTex( pixmap:TPixmap, flags:Int )
	Local mip_level:Int
	If pixmap.dds_fmt <> 0 Then Return ' if dds texture already exists
	Repeat
		glTexImage2D( GL_TEXTURE_2D, mip_level, GL_RGBA, pixmap.width, pixmap.height, 0, GL_RGBA, GL_UNSIGNED_BYTE, Null )
		For Local y:Int = 0 Until pixmap.height
			Local row:Byte Ptr = pixmap.pixels + ( y * pixmap.width ) * 4
			glTexSubImage2D( GL_TEXTURE_2D, mip_level, 0, y, pixmap.width, 1, GL_RGBA, GL_UNSIGNED_BYTE, row )
		Next

		If Not ( flags & MIPMAPPEDIMAGE ) Then Exit
		If pixmap.width > 1 And pixmap.height > 1
			pixmap = ResizePixmap( pixmap, pixmap.width / 2, pixmap.height / 2 )
		Else If pixmap.width > 1
			pixmap = ResizePixmap( pixmap, pixmap.width / 2, pixmap.height )
		Else If pixmap.height > 1
			pixmap = ResizePixmap( pixmap, pixmap.width, pixmap.height / 2 )
		Else
			Exit
		EndIf
		mip_level :+ 1
	Forever

End Function

Function AdjustTexSize( width:Int Var, height:Int Var )

	'calc texture size
	width = Pow2Size( width )
	height = Pow2Size( height )

	Return ' assume this size is fine...
	Rem
	Repeat
		Local t:Int
		glTexImage2D( GL_TEXTURE_2D, 0, 4, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, Null )
		?Not opengles
		glGetTexLevelParameteriv( GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, Varptr t )
		?opengles
		Return
		?
		If t Return
		If width = 1 And height = 1 Then RuntimeError "Unable to calculate tex size"
		If width > 1 width :/ 2
		If height > 1 height :/ 2
	Forever
	EndRem
End Function



Global dead_FBOs:TDynamicArray = New TDynamicArray(32)
Global dead_FBO_seq:Int

'Enqueues a FBO for deletion, to prevent releasing framebuffers on wrong thread.
Function DeleteFBO( FBO:Int,seq:Int )
	If seq<>dead_FBO_seq Return

	dead_FBOs.AddLast(FBO)
End Function

Function CreateFBO:Int(TextureName:Int )
	Local FrameBufferObject:Int
	glGenFramebuffers(1, Varptr FrameBufferObject)
	glBindFramebuffer(GL_FRAMEBUFFER, FrameBufferObject)
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, TextureName, 0)

	' Flush dead FBOs, this ensures to delete FBOs from within the
	' main thread, while Delete() of image frames can happen from subthread
	' too.
	' This also means, it only deletes FBOs if a new is created!
	If dead_FBO_seq = GraphicsSeq
		Local deadFBO:Int = dead_FBOs.RemoveLast()
		While deadFBO <> $FFFFFFFF
			glDeleteFramebuffers(1, Varptr deadFBO) ' gl ignores 0

			deadFBO = dead_FBOs.RemoveLast()
		Wend
	EndIf

	dead_FBO_seq = GraphicsSeq

	Return FrameBufferObject
End Function


Type TDynamicArray

	Private

	Field data:Int Ptr
	Field size:Size_T
	Field capacity:Size_T

	Field guard:TMutex

	Public

	Method New(initialCapacity:Int = 8)
		capacity = initialCapacity
		data = malloc_(Size_T(initialCapacity * 4))
		guard = CreateMutex()
	End Method

	Method AddLast(value:Int)
		guard.Lock()
		If size = capacity Then
			capacity :* 2
			Local d:Byte Ptr = realloc_(data, capacity * 4)
			If Not d Then
				Throw "Failed to allocate more memory"
			End If
			data = d
		End If

		data[size] = value
		size :+ 1
		guard.Unlock()
	End Method

	Method RemoveLast:Int()
		guard.Lock()
		Local v:Int

		If size > 0 Then
			size :- 1
			v = data[size]
		Else
			v = $FFFFFFFF
		End If

		guard.Unlock()

		Return v
	End Method

	Method Delete()
		free_(data)
		CloseMutex(guard)
	End Method

End Type

Function DefaultVShaderSource:String()

	Local str:String = ""

	?opengles	
	str :+ "#version 100~n"
	?Not opengles
	str :+ "#version 120~n"
	?
	str :+ "attribute vec2 vertex_pos;~n"
	str :+ "attribute vec4 vertex_col;~n"
	str :+ "varying vec4 v4_col;~n"
	str :+ "uniform mat4 u_pmatrix;~n"
	str :+ "void main(void) {~n"
	str :+ "	gl_Position=u_pmatrix*vec4(vertex_pos, -1.0, 1.0);~n"
	str :+ "	v4_col=vertex_col;~n"
	str :+ "    gl_PointSize = 1.0;~n"
	str :+ "}"
	
	Return str

End Function

Function DefaultFShaderSource:String()

	Local str:String = ""
	
	?opengles	
	str :+ "#version 100~n"
	str :+ "precision mediump float;~n"
	str :+ "varying vec4 v4_col;~n"
	str :+ "void main(void) {~n"
	str :+ "	gl_FragColor=vec4(v4_col);~n"
	str :+ "}~n"
	?Not opengles
	str :+ "#version 120~n"
	str :+ "varying vec4 v4_col;~n"
	str :+ "void main(void) {~n"
	str :+ "	gl_FragColor=v4_col;~n"
	str :+ "}~n"
	?
	
	Return str

End Function

Function DefaultTextureVShaderSource:String()

	Local str:String = ""

	?opengles
	str :+ "#version 100~n"
	?Not opengles
	str :+ "#version 120~n"
	?
	str :+ "attribute vec2 vertex_pos;~n"
	str :+ "attribute vec4 vertex_col;~n"
	str :+ "attribute vec2 vertex_uv;~n"
	str :+ "varying vec4 v4_col;~n"
	str :+ "varying vec2 v2_tex;~n"
	str :+ "uniform mat4 u_pmatrix;~n"
	str :+ "void main(void) {~n"
	str :+ "	gl_Position=u_pmatrix*vec4(vertex_pos, -1.0, 1.0);~n"
	str :+ "	v4_col=vertex_col;~n"
	str :+ "	v2_tex=vertex_uv;~n"
	str :+ "}"

	Return str

End Function

Function DefaultTextureFShaderSource:String()

	Local str:String = ""

	?opengles	
	str :+ "#version 100~n"
	str :+ "precision mediump float;~n"
	str :+ "uniform sampler2D u_texture0;~n"
	str :+ "uniform bool u_maskblend;~n"
	str :+ "varying vec4 v4_col;~n"
	str :+ "varying vec2 v2_tex;~n"
	str :+ "void main(void) {~n"
	str :+ "    vec4 tex=texture2D(u_texture0, v2_tex) * v4_col;~n"
	str :+ "    if (u_maskblend) {~n"
	str :+ "        if (tex.a < 0.5) {~n"
	str :+ "            discard;~n"
	str :+ "        }~n"
	str :+ "    }~n"
	str :+ "    gl_FragColor = tex;~n"
	str :+ "}~n"
	?Not opengles
	str :+ "#version 120~n"
	str :+ "uniform sampler2D u_texture0;~n"
	str :+ "varying vec4 v4_col;~n"
	str :+ "varying vec2 v2_tex;~n"
	str :+ "void main(void) {~n"
	str :+ "    vec4 tex=texture2D(u_texture0, v2_tex);~n"
	str :+ "	gl_FragColor.rgb=tex.rgb*v4_col.rgb;~n"
	str :+ "    gl_FragColor.a=tex.a*v4_col.a;~n"
	str :+ "}~n"
	?

	Return str

End Function

Type TGL2SDLRenderImageFrame Extends TGLImageFrame
	Field FBO:Int
	Field width:Int
	Field height:Int
	
	Method Draw( x0#,y0#,x1#,y1#,tx#,ty#,sx#,sy#,sw#,sh# ) Override
		Assert seq=GraphicsSeq Else "Image does not exist"

		' Note for a TGLRenderImage the V texture coordinate is flipped compared to the regular TImageFrame.Draw method
		Local u0:Float = sx * uscale
		Local v0:Float = (sy + sh) * vscale
		Local u1:Float = (sx + sw) * uscale
		Local v1:Float = sy * vscale
		
		_driver.DrawTexture( name, u0, v0, u1, v1, x0, y0, x1, y1, tx, ty, Self )
	EndMethod
	
	Function Create:TGL2SDLRenderImageFrame(width:UInt, height:UInt, flags:Int)
		' Need this to enable frame buffer objects - glGenFramebuffers
		If Not glewIsInit
			GlewInit()
			glewIsInit = True
		EndIf
	
		' store so that we can restore once the fbo is created
		Local ScissorTestEnabled:Int = GlIsEnabled(GL_SCISSOR_TEST)
		glDisable(GL_SCISSOR_TEST)
		
		Local TextureName:Int
		glGenTextures(1, Varptr TextureName)
		' inform engine about TextureName being GL_TEXTURE_2D target 
		' do not just call glBindTexture directly!
		BindTex(TextureName)
		'glBindTexture(GL_TEXTURE_2D, TextureName)
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, Null)
		
		If flags & FILTEREDIMAGE
			glTexParameteri GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR
			glTexParameteri GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR
		Else
			glTexParameteri GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST
			glTexParameteri GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST
		EndIf
		
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
		
		Local FrameBufferObject:Int = CreateFBO(TextureName)
		Local RenderTarget:TGL2SDLRenderImageFrame = New TGL2SDLRenderImageFrame
		RenderTarget.name = TextureName
		RenderTarget.FBO = FrameBufferObject
		
		RenderTarget.width = width
		RenderTarget.height = height
		RenderTarget.uscale = 1.0 / width
		RenderTarget.vscale = 1.0 / height
		RenderTarget.u1 = width * RenderTarget.uscale
		RenderTarget.v1 = height * RenderTarget.vscale
		
		If ScissorTestEnabled
			glEnable(GL_SCISSOR_TEST)
		EndIf
		
		Return RenderTarget
	EndFunction
	
Private
	Method Delete()
		If Not seq Then Return
		If Not FBO Then Return

		'delete FBO deferred
		DeleteFBO( FBO, seq )
		FBO = 0
	End Method

	Method New()
	EndMethod
EndType

Public

'============================================================================================'
'============================================================================================'

Type TGLImageFrame Extends TImageFrame

	Field u0:Float, v0:Float, u1:Float, v1:Float, uscale:Float, vscale:Float
	Field name:Int, seq:Int

	Method New()

		seq = GraphicsSeq

	End Method

	Method Delete()

		If Not seq Then Return
		DeleteTex( name, seq )
		seq = 0

	End Method

	Method Draw( x0:Float, y0:Float, x1:Float, y1:Float, tx:Float, ty:Float, sx:Float, sy:Float, sw:Float, sh:Float ) Override

		Assert seq = GraphicsSeq Else "Image does not exist"

		Local u0:Float = sx * uscale
		Local v0:Float = sy * vscale
		Local u1:Float = ( sx + sw ) * uscale
		Local v1:Float = ( sy + sh ) * vscale

		_driver.DrawTexture( name, u0, v0, u1, v1, x0, y0, x1, y1, tx, ty, Self )

	End Method
	
	Function CreateFromPixmap:TGLImageFrame( src:TPixmap, flags:Int )

		'determine tex size
		Local tex_w:Int = src.width
		Local tex_h:Int = src.height
		AdjustTexSize( tex_w, tex_h )
		
		'make sure pixmap fits texture
		Local width:Int = Min( src.width, tex_w )
		Local height:Int = Min( src.height, tex_h )
		If src.width <> width Or src.height <> height Then src = ResizePixmap( src, width, height )

		'create texture pixmap
		Local tex:TPixmap = src
		
		'"smear" right/bottom edges if necessary
		If width < tex_w Or height < tex_h
			tex = TPixmap.Create( tex_w, tex_h, PF_RGBA8888 )
			tex.Paste( src, 0, 0 )
			If width < tex_w
				tex.Paste( src.Window( width - 1, 0, 1, height ), width, 0 )
			EndIf
			If height < tex_h
				tex.Paste( src.Window( 0, height - 1, width, 1 ), 0, height )
				If width < tex_w 
					tex.Paste( src.Window( width - 1, height - 1, 1, 1 ), width, height )
				EndIf
			EndIf
		Else
			If tex.dds_fmt = 0 ' not dds
				If tex.format <> PF_RGBA8888 Then tex = tex.Convert( PF_RGBA8888 )
			EndIf
		EndIf
		
		'create tex
		Local name:Int = CreateTex( tex_w, tex_h, flags, tex )
		
		'upload it
		UploadTex( tex, flags )

		'clean up
		DisableTex()

		'done!
		Local frame:TGLImageFrame = New TGLImageFrame
		frame.name = name
		frame.uscale = 1.0 / tex_w
		frame.vscale = 1.0 / tex_h
		frame.u1 = width * frame.uscale
		frame.v1 = height * frame.vscale
		Return frame

	End Function

End Type

'============================================================================================'
'============================================================================================'

Type TMatrix

	Field grid:Float Ptr = Float Ptr( MemAlloc( 4 * 16 ) )
	
	Method SetOrthographic( pl:Float, pr:Float, pt:Float, pb:Float, pn:Float, pf:Float )

		LoadIdentity()
		grid[00] =  2.0 / ( pr - pl )
		grid[05] =  2.0 / ( pt - pb )
		grid[10] = -2.0 / ( pf - pn )
		grid[12] = -( ( pr + pl ) / ( pr - pl ) )
		grid[13] = -( ( pt + pb ) / ( pt - pb ) )
		grid[14] = -( ( pf + pn ) / ( pf - pn ) )
		grid[15] =  1.0

	End Method
	
	Method Clear()

		For Local i:Int = 0 To 15
			grid[i] = 0.0
		Next

	End Method
	
	Method LoadIdentity()

		Clear()
		grid[00] = 1.0
		grid[05] = 1.0
		grid[10] = 1.0
		grid[15] = 1.0

	End Method

End Type

Type TGLSLShader

	Field source:String
	Field kind:Int
	
	Field id:Int
	
	Method Create:TGLSLShader( source:Object, kind:Int )

		Self.kind = kind
		If Not Load( source ) Then Return Null
		Compile()
		If Not id Then Return Null

		Return Self

	End Method
	
	Method Load:Int( source:Object )

		If String( source ) Then
			Self.source = String( source )
			Return True
		EndIf

		Return False

	End Method

	Method Compile:Int()
		
		If source = "" Then
			'Print "ERROR (CompileShader) No shader source!"
			Return 0
		EndIf
		
		Select kind
		Case GL_VERTEX_SHADER
			'Print "(CompileShader) Compiling vertex shader"
		Case GL_FRAGMENT_SHADER
			'Print "(CompileShader) Compiling fragment shader"
		Default 
			'Print "(CompileShader) Invalid shader type!"
			Return 0
		End Select
		
		id = glCreateShader( kind )
		Local str:Byte Ptr = source.ToCString()
		
		glShaderSource( id, 1, Varptr str, Null )
		glCompileShader( id )
		
		MemFree str
		
		Local success:Int = 0
		glGetShaderiv( id, GL_COMPILE_STATUS, Varptr success )
		
		If Not success Then
			'Print GetShaderErrorLog(id)
			Return 0
		EndIf
		
		'Print "(CompileShader) Successfully compiled shader!"
		'Return id
		
	End Method
	
	Method GetErrorLog:String( pid:Int )

		Local logsize:Int = 0
		glGetShaderiv( pid, GL_INFO_LOG_LENGTH, Varptr logsize )

		Local msg:Byte[logsize]
		Local size:Int = 0

		glGetShaderInfoLog( pid, logsize, Varptr size, Varptr msg[0] )

		Local str:String = ""
		For Local i:Int = 0 To MSG.length - 1
			str :+ Chr( msg[i] )
		Next

		Return str

	End Method
	
End Type

Type TGLSLProgram

	Field id:Int

	Field attrib_pos:Int
	Field attrib_uv:Int
	Field attrib_col:Int

	Field uniform_ProjMatrix:Int	'NOTE: Acts as glModelViewProjectionMatrix.
	Field uniform_Texture0:Int
	Field uniform_maskblend:Int = -1
	'Field uniform_Color:Int

	Method Create:TGLSLProgram( vs:TGLSLShader, fs:TGLSLShader )

		If glIsShader( vs.id ) = GL_FALSE Then 
			'Print "ERROR (CreateShaderProgram) pvshader is not a valid shader!"
			Return Null
		EndIf

		If glIsShader( fs.id ) = GL_FALSE Then
			'Print "ERROR (CreateShaderProgram) pfshader is not a valid shader!"
			Return Null
		EndIf

		id = glCreateProgram()
		glAttachShader( id, vs.id )
		glAttachShader( id, fs.id )
		glLinkProgram( id )
		UpdateLayout()

		Return Self
		
	End Method

	Method Validate()

		If glIsProgram( id ) = GL_FALSE Then
			'Print "ERROR (ValidateShaderProgram) Supplied id is not a shader program!"
			Return
		EndIf
		
		Local status:Int
		
		glValidateProgram( id )
		glGetProgramiv( id, GL_VALIDATE_STATUS, Varptr status )
		
		If status = GL_FALSE Then
			'Print "ERROR (ValidateShaderprogram) Supplied program is not valid! (in context)"
			Return
		EndIf
		
		Return
	
	End Method

	Method Use()

		glUseProgram( id )
		If uniform_Texture0 > -1 Then glActiveTexture( GL_TEXTURE0 )

	End Method

	Method UpdateLayout()

		If Not glIsProgram( id ) Then
			'Print "(UpdateShaderLayout) Active is not a valid shader program!"
			Return
		EndIf

		attrib_pos = glGetAttribLocation( id, "vertex_pos" )
		attrib_uv = glGetAttribLocation( id, "vertex_uv" )
		attrib_col = glGetAttribLocation( id, "vertex_col" )

		uniform_ProjMatrix = glGetUniformLocation( id, "u_pmatrix" )
		uniform_Texture0 = glGetUniformLocation( id, "u_texture0" )
		?opengles
		uniform_maskblend = glGetUniformLocation( id, "u_maskblend" )
		?
		'uniform_Color = glGetUniformLocation( id, "u_color" )

	End Method

	'Method EnableData( vert_buffer:Int, uv_buffer:Int, col_buffer:Int, matrix:Float Ptr )
	Method EnableData( vert_array:Float Ptr, uv_array:Float Ptr, col_array:Float Ptr, matrix:Float Ptr )

		If attrib_pos >= 0 Then
			glEnableVertexAttribArray( attrib_pos )
			glVertexAttribPointer( attrib_pos, 2, GL_FLOAT, GL_FALSE, 0, vert_array )
		EndIf

		If attrib_uv >= 0 Then
			glEnableVertexAttribArray( attrib_uv )
			glVertexAttribPointer( attrib_uv, 2, GL_FLOAT, GL_FALSE, 0, uv_array )
		EndIf

		If attrib_col >= 0 Then
			glEnableVertexAttribArray( attrib_col )
			glVertexAttribPointer( attrib_col, 4, GL_FLOAT, GL_FALSE, 0, col_array )
		EndIf

		If uniform_ProjMatrix >= 0 Then
			glUniformMatrix4fv( uniform_ProjMatrix, 1, False, matrix )
		EndIf

		If uniform_Texture0 >= 0 Then
			glUniform1i( uniform_Texture0, 0 )
		EndIf

		'If uniform_Color >= 0 Then
		'	glUniform4f( uniform_Color, color4f[0], color4f[1], color4f[2], color4f[3] )
		'EndIf

	End Method
	
	Method DisableData()

		If attrib_pos >= 0 Then
			glDisableVertexAttribArray( attrib_pos )
		EndIf

		If attrib_uv >= 0 Then
			glDisableVertexAttribArray( attrib_uv )
		EndIf

		If attrib_col >= 0 Then
			glDisableVertexAttribArray( attrib_col )
		EndIf

	End Method

End Type

'============================================================================================'
'============================================================================================'

Type TGL2Max2DDriver Extends TMax2DDriver

?Not emscripten
	Const BATCHSIZE:Int = 32767 ' how many entries that can be stored in batch before a draw call is required
?emscripten
	Const BATCHSIZE:Int = 8192  ' how many entries that can be stored in batch before a draw call is required
?

	' has driver been initialized?

	Field inited:Int

	' pre-built element arrays

	Field TRI_INDS:Short Ptr = Short Ptr( MemAlloc(2 * BATCHSIZE * 3) )
	Field QUAD_INDS:Short Ptr = Int Ptr( MemAlloc(2 * BATCHSIZE * 6) )

	' vertex attribute arrays

	Field vert_array:Float Ptr = Float Ptr( MemAlloc( 4 * BATCHSIZE * 3 ) )
	Field uv_array:Float Ptr = Float Ptr( MemAlloc( 4 * BATCHSIZE * 2 ) )
	Field col_array:Float Ptr = Float Ptr( MemAlloc( 4 * BATCHSIZE * 4 ) )
	
	' colo(u)rs
	Field color4f:Float Ptr = Float Ptr( MemAlloc( 4 * 4 ) )
	
	Field imgCache:TList = New TList

	' constants for primitive_id rendering

	Const PRIMITIVE_PLAIN_TRIANGLE:Int = 1
	Const PRIMITIVE_DOT:Int = 2
	Const PRIMITIVE_LINE:Int = 3
	Const PRIMITIVE_IMAGE:Int = 4
	Const PRIMITIVE_TRIANGLE_FAN:Int = 5
	Const PRIMITIVE_TRIANGLE_STRIP:Int = 6
	Const PRIMITIVE_TEXTURED_TRIANGLE:Int = 7

	Const PRIMITIVE_CLS:Int = 8
	Const PRIMITIVE_VIEWPORT:Int = 9

	' variables for tracking

	Field vert_index:Int
	Field quad_index:Int
	Field primitive_id:Int
	Field texture_id:Int
	Field blend_id:Int
'	Field element_array:Int[BATCHSIZE * 2]
'	Field element_index:Int
'	Field vert_buffer:Int
'	Field uv_buffer:Int
'	Field col_buffer:Int
'	Field element_buffer:Int

	' projection matrix

	Field u_pmatrix:TMatrix

	' current shader program and defaults

	Field activeProgram:TGLSLProgram
	Field defaultVShader:TGLSLShader
	Field defaultFShader:TGLSLShader
	Field defaultProgram:TGLSLProgram
	Field defaultTextureVShader:TGLSLShader
	Field defaultTextureFShader:TGLSLShader
	Field defaultTextureProgram:TGLSLProgram

	' current z layer for drawing (NOT USED)

	Field layer:Float

	Method Create:TGL2Max2DDriver()

		If Not SDLGraphicsDriver() Then Return Null

		Return Self

	End Method

	'graphics driver overrides
	Method GraphicsModes:TGraphicsMode[]() Override
		Return SDLGraphicsDriver().GraphicsModes()
	End Method

	Method AttachGraphics:TMax2DGraphics( widget:Byte Ptr, flags:Long ) Override
		Local g:TSDLGraphics = SDLGraphicsDriver().AttachGraphics( widget, flags )

		If g Then Return TMax2DGraphics.Create( g, Self )
	End Method
	
	Method CreateGraphics:TMax2DGraphics( width:Int, height:Int, depth:Int, hertz:Int, flags:Long, x:Int, y:Int ) Override
		Local g:TSDLGraphics = SDLGraphicsDriver().CreateGraphics( width, height, depth, hertz, flags | SDL_GRAPHICS_GL, x, y )
		
		If g Then Return TMax2DGraphics.Create( g, Self )
	End Method

	Method SetGraphics( g:TGraphics ) Override
		If Not g
			TMax2DGraphics.ClearCurrent()
			SDLGraphicsDriver().SetGraphics(Null)
			inited = Null

			Return
		EndIf

		Local t:TMax2DGraphics = TMax2DGraphics( g )
		?Not opengles
		Assert t And TSDLGraphics( t._backendGraphics )
		?

		SDLGraphicsDriver().SetGraphics(t._backendGraphics)

		ResetGLContext(t)

		t.MakeCurrent()
	End Method
	
	Method ResetGLContext( g:TGraphics )

		Local gw:Int, gh:Int, gd:Int, gr:Int, gf:Long, gx:Int, gy:Int
		g.GetSettings( gw, gh, gd, gr, gf, gx, gy )

		If Not inited Then
			Init()
			inited = True
		End If

		state_blend = 0
		state_boundtex = 0
		state_texenabled = 0
		glDisable( GL_TEXTURE_2D )

		'glMatrixMode( GL_PROJECTION )
		'glLoadIdentity()
		'glOrtho( 0, gw, gh, 0, -1, 1 )
		'glMatrixMode( GL_MODELVIEW )
		'glLoadIdentity()
		'glViewport( 0, 0, gw, gh )

		u_pmatrix = New TMatrix
		u_pmatrix.SetOrthographic( 0, gw, 0, gh, -1, 1 )

		' Need glew to enable "glBlendFuncSeparate" (required for
		' alpha blending on non-opaque backgrounds like render images)
		If Not glewIsInit
			GlewInit()
			glewIsInit = True
		EndIf

		' Create default back buffer render image - the FBO will be value 0 which is the default for the existing backbuffer
		Local BackBufferRenderImageFrame:TGL2SDLRenderImageFrame = New TGL2SDLRenderImageFrame
		BackBufferRenderImageFrame.width = gw
		BackBufferRenderImageFrame.height = gh
	
		' cache it
		_BackBufferRenderImageFrame = BackBufferRenderImageFrame
		_CurrentRenderImageFrame = _BackBufferRenderImageFrame
	End Method
	
	Method Flip:Int( sync:Int ) Override
		Flush()

		SDLGraphicsDriver().Flip(sync)
?ios
		glViewport(0, 0, GraphicsWidth(), GraphicsHeight())
?
	End Method

	Method ToString:String() Override
		Return "OpenGL"
	End Method

	Method ApiIdentifier:String() Override
		Return "SDL.OpenGL (GL2SDL)"
	End Method

	Method CreateFrameFromPixmap:TGLImageFrame( pixmap:TPixmap, flags:Int ) Override
		Return TGLImageFrame.CreateFromPixmap( pixmap, flags )
	End Method

	Method SetBlend( blend:Int ) Override
		If state_blend = blend Return

		?opengles
		If state_blend = MASKBLEND And activeProgram And activeProgram.uniform_maskblend >= 0 Then
			glUniform1i( activeProgram.uniform_maskblend, 0 )
		End If
		?

		state_blend = blend

		Select blend
		Case MASKBLEND
		?Not opengles
			glDisable( GL_BLEND )
			glEnable( GL_ALPHA_TEST )
			glAlphaFunc( GL_GEQUAL, 0.5 )
		?opengles
		If activeProgram And activeProgram.uniform_maskblend >= 0 Then
			glUniform1i( activeProgram.uniform_maskblend, 1 )
		EndIf
		?
		Case SOLIDBLEND
			glDisable( GL_BLEND )
			?Not opengles
			glDisable( GL_ALPHA_TEST )
			?
		Case ALPHABLEND
			glEnable( GL_BLEND )
			' simple alphablend:
			'glBlendFunc( GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA )
			' more advanced blend function allows blending on a non-opaque
			' "background" (eg. render image)
			glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
			?Not opengles
			glDisable( GL_ALPHA_TEST )
			?
		Case LIGHTBLEND
			glEnable( GL_BLEND )
			glBlendFunc( GL_SRC_ALPHA, GL_ONE )
			?Not opengles
			glDisable( GL_ALPHA_TEST )
			?
		Case SHADEBLEND
			glEnable( GL_BLEND )
			glBlendFunc( GL_DST_COLOR, GL_ZERO )
			?Not opengles
			glDisable( GL_ALPHA_TEST )
			?
		Default
			glDisable( GL_BLEND )
			?Not opengles
			glDisable( GL_ALPHA_TEST )
			?
		End Select
	End Method

	Method SetAlpha( alpha:Float ) Override
		If alpha > 1.0 Then alpha = 1.0
		If alpha < 0.0 Then alpha = 0.0
		color4f[3] = alpha
	End Method

	Method SetLineWidth( width:Float ) Override
		glLineWidth( width )
	End Method

	Method SetColor( red:Int, green:Int, blue:Int ) Override
		color4f[0] = Min( Max( red, 0 ), 255 ) / 255.0
		color4f[1] = Min( Max( green, 0 ), 255 ) / 255.0
		color4f[2] = Min( Max( blue, 0 ), 255 ) / 255.0
	End Method

	Method SetClsColor( red:Int, green:Int, blue:Int, alpha:Float ) Override
		red = Min(Max(red,0),255)
		green = Min(Max(green,0),255)
		blue = Min(Max(blue,0),255)

		glClearColor(red/255.0, green/255.0, blue/255.0, alpha)
	End Method
	
	Method SetViewport( x:Int, y:Int, w:Int, h:Int ) Override
		'render what has been batched till now
		FlushTest( PRIMITIVE_VIEWPORT )

		_GLScissor_BMaxViewport.x = x
		_GLScissor_BMaxViewport.y = y
		_GLScissor_BMaxViewport.width = w
		_GLScissor_BMaxViewport.height = h
		SetScissor(x, y, w, h)
	End Method

	Method SetTransform( xx:Float, xy:Float, yx:Float, yy:Float ) Override
		ix = xx
		iy = xy
		jx = yx
		jy = yy
	End Method

	Method Cls() Override
		'render what has been batched till now - maybe this happens
		'with an restricted viewport
		FlushTest( PRIMITIVE_CLS )

		glClear( GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT )
	End Method

	Method Plot( x:Float, y:Float ) Override
		FlushTest( PRIMITIVE_DOT )

		Local in:Int = vert_index * 2

		vert_array[in + 0] = x
		vert_array[in + 1] = y

		in = vert_index * 4

		col_array[in + 0] = color4f[0] 'red
		col_array[in + 1] = color4f[1] 'green
		col_array[in + 2] = color4f[2] 'blue
		col_array[in + 3] = color4f[3] 'alpha

		vert_index :+ 1

	End Method

	Method DrawLine( x0:Float, y0:Float, x1:Float, y1:Float, tx:Float, ty:Float ) Override
		FlushTest( PRIMITIVE_LINE )

		Local in:Int = vert_index * 2

		vert_array[in + 0] = x0 * ix + y0 * iy + tx + 0.5
		vert_array[in + 1] = x0 * jx + y0 * jy + ty + 0.5

		vert_array[in + 2] = x1 * ix + y1 * iy + tx + 0.5
		vert_array[in + 3] = x1 * jx + y1 * jy + ty + 0.5

		in = vert_index * 4

		col_array[in + 0] = color4f[0] 'red
		col_array[in + 1] = color4f[1] 'green
		col_array[in + 2] = color4f[2] 'blue
		col_array[in + 3] = color4f[3] 'alpha

		col_array[in + 4] = color4f[0] 'red
		col_array[in + 5] = color4f[1] 'green
		col_array[in + 6] = color4f[2] 'blue
		col_array[in + 7] = color4f[3] 'alpha

		vert_index :+ 2
	End Method

	Method DrawRect( x0:Float, y0:Float, x1:Float, y1:Float, tx:Float, ty:Float ) Override
		FlushTest( PRIMITIVE_PLAIN_TRIANGLE )

		Local in:Int = vert_index * 2

		vert_array[in    ] = x0 * ix + y0 * iy + tx		'topleft x
		vert_array[in + 1] = x0 * jx + y0 * jy + ty		'topleft y
		vert_array[in + 2] = x1 * ix + y0 * iy + tx		'topright x
		vert_array[in + 3] = x1 * jx + y0 * jy + ty		'topright y
		vert_array[in + 4] = x1 * ix + y1 * iy + tx		'bottomright x
		vert_array[in + 5] = x1 * jx + y1 * jy + ty		'bottomright x
		vert_array[in + 6] = x0 * ix + y1 * iy + tx		'bottomleft x
		vert_array[in + 7] = x0 * jx + y1 * jy + ty		'bottomleft y

		in = vert_index * 4

		col_array[in + 00] = color4f[0] 'red
		col_array[in + 01] = color4f[1] 'green
		col_array[in + 02] = color4f[2] 'blue
		col_array[in + 03] = color4f[3] 'alpha

		col_array[in + 04] = color4f[0] 'red
		col_array[in + 05] = color4f[1] 'green
		col_array[in + 06] = color4f[2] 'blue
		col_array[in + 07] = color4f[3] 'alpha

		col_array[in + 08] = color4f[0] 'red
		col_array[in + 09] = color4f[1] 'green
		col_array[in + 10] = color4f[2] 'blue
		col_array[in + 11] = color4f[3] 'alpha

		col_array[in + 12] = color4f[0] 'red
		col_array[in + 13] = color4f[1] 'green
		col_array[in + 14] = color4f[2] 'blue
		col_array[in + 15] = color4f[3] 'alpha

		vert_index :+ 4
		quad_index :+ 1
	End Method

	Method DrawOval( x0:Float, y0:Float, x1:Float, y1:Float, tx:Float, ty:Float ) Override
		' TRIANGLE_FAN (no batching)
		FlushTest( PRIMITIVE_TRIANGLE_FAN )

		Local xr:Float = ( x1 - x0 ) * 0.5
		Local yr:Float = ( y1 - y0 ) * 0.5
		Local segs:Int = Abs( xr ) + Abs( yr )

		segs = Max( segs, 12 ) &~ 3

		x0 :+ xr
		y0 :+ yr

		Local in:Int = vert_index * 2

		vert_array[in    ] = x0 * ix + y0 * iy + tx
		vert_array[in + 1] = x0 * jx + y0 * jy + ty

		Local off:Int = 2

		For Local i:Int = 0 To segs
			Local th:Float = i * 360:Float / segs
			Local x:Float = x0 + Cos( th ) * xr
			Local y:Float = y0 - Sin( th ) * yr
			vert_array[in + off    ] = x * ix + y * iy + tx
			vert_array[in + off + 1] = x * jx + y * jy + ty
			off :+ 2
		Next

		in = vert_index * 4

		col_array[in + 0] = color4f[0] 'red
		col_array[in + 1] = color4f[1] 'green
		col_array[in + 2] = color4f[2] 'blue
		col_array[in + 3] = color4f[3] 'alpha

		off = 4

		For Local i:Int = 0 To segs
			col_array[in + off + 0] = color4f[0] 'red
			col_array[in + off + 1] = color4f[1] 'green
			col_array[in + off + 2] = color4f[2] 'blue
			col_array[in + off + 3] = color4f[3] 'alpha
			off :+ 4
		Next

		vert_index :+ segs + 2
	End Method

	Method DrawPoly( xy:Float[], handle_x:Float, handle_y:Float, origin_x:Float, origin_y:Float, indices:Int[] ) Override
		If xy.length < 6 Or ( xy.length & 1 ) Then Return

		' TRIANGLE_FAN (no batching)
		FlushTest( PRIMITIVE_TRIANGLE_FAN )

		Local in:Int = vert_index * 2

		For Local i:Int = 0 Until xy.length Step 2
			Local x:Float = handle_x + xy[i]
			Local y:Float = handle_y + xy[i + 1]
			vert_array[in + i    ] = x * ix + y * iy + origin_x
			vert_array[in + i + 1] = x * jx + y * jy + origin_y
		Next

		in = vert_index * 4

		For Local i:Int = 0 Until xy.length / 2
			col_array[in + i * 4    ] = color4f[0] 'red
			col_array[in + i * 4 + 1] = color4f[1] 'green
			col_array[in + i * 4 + 2] = color4f[2] 'blue
			col_array[in + i * 4 + 3] = color4f[3] 'alpha
		Next

		vert_index :+ xy.length / 2

	End Method

	Method DrawPixmap( p:TPixmap, x:Int, y:Int ) Override
		Local blend:Int = state_blend
		SetBlend( SOLIDBLEND )

		Local t:TPixmap = p
		If t.format <> PF_RGBA8888 Then t = ConvertPixmap( t, PF_RGBA8888 )

		Local img:TImage = LoadImage(t)
		DrawImage( img, x, y )

		SetBlend( blend )
	End Method

	Method DrawTexture( name:Int, u0:Float, v0:Float, u1:Float, v1:Float, x0:Float, y0:Float, x1:Float, y1:Float, tx:Float, ty:Float, img:TImageFrame = Null )
		FlushTest( PRIMITIVE_TEXTURED_TRIANGLE, name )

		Local in:Int = vert_index * 2

		uv_array[in    ] = u0		'topleft x
		uv_array[in + 1] = v0		'topleft y
		uv_array[in + 2] = u1		'topright x
		uv_array[in + 3] = v0		'topright y
		uv_array[in + 4] = u1		'bottomright x
		uv_array[in + 5] = v1		'bottomright y
		uv_array[in + 6] = u0		'bottomleft x
		uv_array[in + 7] = v1		'bottomleft y

		vert_array[in    ] = x0 * ix + y0 * iy + tx		'topleft x
		vert_array[in + 1] = x0 * jx + y0 * jy + ty		'topleft y
		vert_array[in + 2] = x1 * ix + y0 * iy + tx		'topright x
		vert_array[in + 3] = x1 * jx + y0 * jy + ty		'topright y
		vert_array[in + 4] = x1 * ix + y1 * iy + tx		'bottomright x
		vert_array[in + 5] = x1 * jx + y1 * jy + ty		'bottomright x
		vert_array[in + 6] = x0 * ix + y1 * iy + tx		'bottomleft x
		vert_array[in + 7] = x0 * jx + y1 * jy + ty		'bottomleft y

		in = vert_index * 4

		col_array[in + 00] = color4f[0] 'red
		col_array[in + 01] = color4f[1] 'green
		col_array[in + 02] = color4f[2] 'blue
		col_array[in + 03] = color4f[3] 'alpha

		col_array[in + 04] = color4f[0] 'red
		col_array[in + 05] = color4f[1] 'green
		col_array[in + 06] = color4f[2] 'blue
		col_array[in + 07] = color4f[3] 'alpha

		col_array[in + 08] = color4f[0] 'red
		col_array[in + 09] = color4f[1] 'green
		col_array[in + 10] = color4f[2] 'blue
		col_array[in + 11] = color4f[3] 'alpha

		col_array[in + 12] = color4f[0] 'red
		col_array[in + 13] = color4f[1] 'green
		col_array[in + 14] = color4f[2] 'blue
		col_array[in + 15] = color4f[3] 'alpha

		vert_index :+ 4
		quad_index :+ 1
		
		If img Then
			imgCache.AddLast(img)
		End If
	End Method

	Method GrabPixmap:TPixmap( x:Int, y:Int, w:Int, h:Int ) Override
		Local blend:Int = state_blend
		SetBlend( SOLIDBLEND )
		Local p:TPixmap = CreatePixmap( w, h, PF_RGBA8888 )

		'The default backbuffer in Max2D was opaque so overwrote any
		'trash data of a freshly created pixmap. Potentially transparent
		'backbuffers require a complete transparent pixmap to start with.
		p.ClearPixels(0)

		' flush everything to ensure there's something to read
		Flush()
		If _CurrentRenderImageFrame and _CurrentRenderImageFrame <> _BackbufferRenderImageFrame
			glReadPixels(x, _CurrentRenderImageFrame.height - h - y, w, h, GL_RGBA, GL_UNSIGNED_BYTE, p.pixels)
		Else
			glReadPixels(x, _BackbufferRenderImageFrame.height - h - y, w, h, GL_RGBA, GL_UNSIGNED_BYTE, p.pixels)
		EndIf
		p = YFlipPixmap( p )
		SetBlend( blend )
		Return p
	End Method

	Method SetResolution( width:Float, height:Float ) Override
		u_pmatrix.SetOrthographic( 0, width, 0, height, -1, 1 )
	End Method

	Method Init()

		?Not opengles
		glewinit()
		?

		color4f[0] = 1.0
		color4f[1] = 1.0
		color4f[2] = 1.0
		color4f[3] = 1.0

		For Local i:Int = 0 Until BATCHSIZE
			Local in:Int = i * 3
			TRI_INDS[in    ] = in
			TRI_INDS[in + 1] = in + 1
			TRI_INDS[in + 2] = in + 2
		Next
		For Local i:Int = 0 Until BATCHSIZE
			Local i4:Int = i * 4
			Local i6:Int = i * 6
			QUAD_INDS[i6    ] = i4
			QUAD_INDS[i6 + 1] = i4 + 1
			QUAD_INDS[i6 + 2] = i4 + 2
			QUAD_INDS[i6 + 3] = i4 + 2
			QUAD_INDS[i6 + 4] = i4 + 3
			QUAD_INDS[i6 + 5] = i4
		Next

		' set up shaders
		defaultVShader = New TGLSLShader.Create( DefaultVShaderSource(), GL_VERTEX_SHADER )
		defaultFShader = New TGLSLShader.Create( DefaultFShaderSource(), GL_FRAGMENT_SHADER )
		defaultProgram = New TGLSLProgram.Create( defaultVShader, defaultFShader )

		defaultTextureVShader = New TGLSLShader.Create( DefaultTextureVShaderSource(), GL_VERTEX_SHADER )
		defaultTextureFShader = New TGLSLShader.Create( DefaultTextureFShaderSource(), GL_FRAGMENT_SHADER )
		defaultTextureProgram = New TGLSLProgram.Create( defaultTextureVShader, defaultTextureFShader )

		vert_index = 0
		quad_index = 0
		primitive_id = 0
		texture_id = -1
		blend_id = SOLIDBLEND

	End Method

	Method FlushTest( prim_id:Int, tex_id:Int = -1 )

		Select primitive_id
		Case PRIMITIVE_TRIANGLE_FAN, PRIMITIVE_TRIANGLE_STRIP	'Always flush...
			Flush()

		Default
			If prim_id <> primitive_id Or ..
			vert_index > BATCHSIZE - 256 Or ..
			state_blend <> blend_id Or ..
			tex_id <> texture_id Then
				Flush()
			EndIf

		End Select
		primitive_id = prim_id
		texture_id = tex_id
		blend_id = state_blend

	End Method
	
	Method Flush()

		Select primitive_id
		Case PRIMITIVE_PLAIN_TRIANGLE
			If quad_index = 0 Then Return
			If activeProgram <> defaultProgram Then
				activeProgram = defaultProgram
				activeProgram.Use()
			EndIf
		Case PRIMITIVE_TEXTURED_TRIANGLE
			If quad_index = 0 Then Return
			If activeProgram <> defaultTextureProgram
				activeProgram = defaultTextureProgram
				activeProgram.Use()
			EndIf
		Case PRIMITIVE_DOT, PRIMITIVE_LINE, PRIMITIVE_TRIANGLE_FAN, PRIMITIVE_TRIANGLE_STRIP
			If vert_index = 0 Then Return
			If activeProgram <> defaultProgram Then
				activeProgram = defaultProgram
				activeProgram.Use()
			EndIf
		Default
			Return
		End Select

		If activeProgram Then
			
			' additional tests. validate shaderprogram and buffer. shader program validation takes
			' context into consideration, so do it right before drawing
			
			' NOTE: This should probably happen, but not on every Flush().
			'activeProgram.Validate()
			
			' somewhat interesting? default framebuffer should not return any errors
			' NOTE: 36062 seems to be an erroneous error code (ie opengl returns something it shouldnt)
			'Local status:Int = glCheckFramebufferStatus( GL_FRAMEBUFFER )
			'Select status
			'Case GL_FRAMEBUFFER_COMPLETE
				'Print "valid framebuffer"
			'Default
				'Print "status: " + status
			'End Select

			activeProgram.EnableData( vert_array, uv_array, col_array, u_pmatrix.grid )

			?opengles
			If activeProgram.uniform_maskblend >= 0 Then
				glUniform1i( activeProgram.uniform_maskblend, 0 )
			EndIf
			?

			Select blend_id
			Case MASKBLEND
			?Not opengles
				glDisable( GL_BLEND )
				glEnable( GL_ALPHA_TEST )
				glAlphaFunc( GL_GEQUAL, 0.5 )
			?opengles
				If activeProgram.uniform_maskblend >= 0 Then
					glUniform1i( activeProgram.uniform_maskblend, 1 )
				End If
			?
			Case SOLIDBLEND
				glDisable( GL_BLEND )
				?Not opengles
				glDisable( GL_ALPHA_TEST )
				?
			Case ALPHABLEND
				glEnable( GL_BLEND )
				' simple alphablend:
				'glBlendFunc( GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA )
				' more advanced blend function allows blending on a non-opaque
				' "background" (eg. render image)
				glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
				?Not opengles
				glDisable( GL_ALPHA_TEST )
				?
			Case LIGHTBLEND
				glEnable( GL_BLEND )
				glBlendFunc( GL_SRC_ALPHA, GL_ONE )
				?Not opengles
				glDisable( GL_ALPHA_TEST )
				?
			Case SHADEBLEND
				glEnable( GL_BLEND )
				glBlendFunc( GL_DST_COLOR, GL_ZERO )
				?Not opengles
				glDisable( GL_ALPHA_TEST )
				?
			Default
				glDisable( GL_BLEND )
				?Not opengles
				glDisable( GL_ALPHA_TEST )
				?
			End Select

			Select primitive_id
			Case PRIMITIVE_PLAIN_TRIANGLE
				glDrawElements( GL_TRIANGLES, quad_index * 6, GL_UNSIGNED_SHORT, QUAD_INDS )
			Case PRIMITIVE_TEXTURED_TRIANGLE
				EnableTex( texture_id )
				glDrawElements( GL_TRIANGLES, quad_index * 6, GL_UNSIGNED_SHORT, QUAD_INDS )
				DisableTex()

				imgCache.Clear()
			Case PRIMITIVE_DOT
				glDrawArrays( GL_POINTS, 0, vert_index )
			Case PRIMITIVE_LINE
				glDrawArrays( GL_LINES, 0, vert_index )
			Case PRIMITIVE_TRIANGLE_FAN
				glDrawArrays( GL_TRIANGLE_FAN, 0, vert_index )
			Case PRIMITIVE_TRIANGLE_STRIP
				glDrawArrays( GL_TRIANGLE_STRIP, 0, vert_index )
			End Select
			
			activeProgram.DisableData()
			glUseProgram( 0 )
			activeProgram = Null
		End If

		vert_index = 0
		quad_index = 0

	End Method

	'NOTE: Unnecessary, for the time being.
'	Method UpdateBuffers()
'
'		If vert_buffer = 0 Then glGenBuffers( 1, Varptr vert_buffer )
'		If uv_buffer = 0 Then glGenBuffers( 1, Varptr uv_buffer )
'		If col_buffer = 0 Then glGenBuffers( 1, Varptr col_buffer )
'		If element_buffer = 0 Then glGenBuffers( 1, Varptr element_buffer )
'
'		glBindBuffer( GL_ARRAY_BUFFER, vert_buffer )
'		glBufferData( GL_ARRAY_BUFFER, vert_index * 12, vert_array, GL_DYNAMIC_DRAW )
'
'		glBindBuffer( GL_ARRAY_BUFFER, uv_buffer)
'		glBufferData( GL_ARRAY_BUFFER, vert_index * 8, uv_array, GL_DYNAMIC_DRAW )
'
'		glBindBuffer( GL_ARRAY_BUFFER, col_buffer )
'		glBufferData( GL_ARRAY_BUFFER, vert_index * 16, col_array, GL_DYNAMIC_DRAW )
'
'		glBindBuffer( GL_ELEMENT_ARRAY_BUFFER, element_buffer)
'		glBufferData( GL_ELEMENT_ARRAY_BUFFER, element_index * 12, element_array, GL_DYNAMIC_DRAW )
'
'	End Method

	Method CreateRenderImageFrame:TImageFrame(width:UInt, height:UInt, flags:Int) Override
		Return TGL2SDLRenderImageFrame.Create(width, height, flags)
	EndMethod
	
	Method SetRenderImageFrame(RenderImageFrame:TImageFrame) Override		
		If RenderImageFrame = _CurrentRenderImageFrame
			Return
		EndIf
		
		Flush()
		
		glBindFrameBuffer(GL_FRAMEBUFFER, TGL2SDLRenderImageFrame(RenderImageFrame).FBO)
		_CurrentRenderImageFrame = TGL2SDLRenderImageFrame(RenderImageFrame)
		
		Local vp:Rect = _GLScissor_BMaxViewport
		SetScissor(vp.x, vp.y, vp.width, vp.height)
		SetMatrixAndViewportToCurrentRenderImage()
	EndMethod
	
	Method SetBackbuffer()
		SetRenderImageFrame(_BackBufferRenderImageFrame)
	EndMethod
	
Private
	Method SetMatrixAndViewportToCurrentRenderImage()
		u_pmatrix.SetOrthographic( 0, _CurrentRenderImageFrame.width, 0, _CurrentRenderImageFrame.height, -1, 1 )
		glViewport(0, 0, _CurrentRenderImageFrame.width, _CurrentRenderImageFrame.height)
	EndMethod

	Method SetScissor(x:Int, y:Int, w:Int, h:Int)
		Local ri:TImageFrame = _CurrentRenderImageFrame
		If x = 0  And y = 0 And w = _CurrentRenderImageFrame.width And h = _CurrentRenderImageFrame.height
			glDisable(GL_SCISSOR_TEST)
		Else
			glEnable(GL_SCISSOR_TEST)
			glScissor(x, _CurrentRenderImageFrame.height - y - h, w, h)
		EndIf
	EndMethod
End Type

Rem
bbdoc: Get OpenGL Max2D Driver
about:
The returned driver can be used with #SetGraphicsDriver to enable OpenGL Max2D rendering.
End Rem
Function GL2Max2DDriver:TGL2Max2DDriver()
	'Print "GL2 (with shaders) Active"
	Global _done:Int
	If Not _done
		_driver = New TGL2Max2DDriver.Create()
		_done = True
	EndIf
	Return _driver
End Function

Local driver:TGL2Max2DDriver = GL2Max2DDriver()
If driver SetGraphicsDriver driver
