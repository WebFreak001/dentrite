/// OpenGL 3.3 core subset, loaded at run time through a proc address callback.
module dentrite.c.gl;

alias GLenum = uint;      /// enum
alias GLuint = uint;      /// unsigned
alias GLint = int;        /// signed
alias GLsizei = int;      /// size
alias GLboolean = ubyte;  /// 0 or 1
alias GLbitfield = uint;  /// bit mask
alias GLfloat = float;    /// float
alias GLchar = char;      /// string char
alias GLsizeiptr = ptrdiff_t; /// buffer size
alias GLintptr = ptrdiff_t;   /// buffer offset

enum : GLenum
{
    GL_FALSE = 0,
    GL_TRUE = 1,
    GL_TRIANGLES = 0x0004,
    GL_DEPTH_BUFFER_BIT = 0x0100,
    GL_COLOR_BUFFER_BIT = 0x4000,
    GL_LESS = 0x0201,
    GL_ONE = 1,
    GL_SRC_ALPHA = 0x0302,
    GL_ONE_MINUS_SRC_ALPHA = 0x0303,
    GL_CULL_FACE = 0x0B44,
    GL_DEPTH_TEST = 0x0B71,
    GL_BLEND = 0x0BE2,
    GL_SCISSOR_TEST = 0x0C11,
    GL_UNPACK_ROW_LENGTH = 0x0CF2,
    GL_UNPACK_ALIGNMENT = 0x0CF5,
    GL_PACK_ALIGNMENT = 0x0D05,
    GL_TEXTURE_2D = 0x0DE1,
    GL_UNSIGNED_BYTE = 0x1401,
    GL_UNSIGNED_INT = 0x1405,
    GL_FLOAT = 0x1406,
    GL_RGBA = 0x1908,
    GL_VERSION = 0x1F02,
    GL_RENDERER = 0x1F01,
    GL_NEAREST = 0x2600,
    GL_LINEAR = 0x2601,
    GL_TEXTURE_MAG_FILTER = 0x2800,
    GL_TEXTURE_MIN_FILTER = 0x2801,
    GL_TEXTURE_WRAP_S = 0x2802,
    GL_TEXTURE_WRAP_T = 0x2803,
    GL_CLAMP_TO_EDGE = 0x812F,
    GL_RGBA8 = 0x8058,
    GL_TEXTURE0 = 0x84C0,
    GL_ARRAY_BUFFER = 0x8892,
    GL_ELEMENT_ARRAY_BUFFER = 0x8893,
    GL_STREAM_DRAW = 0x88E0,
    GL_STATIC_DRAW = 0x88E4,
    GL_DYNAMIC_DRAW = 0x88E8,
    GL_FRAGMENT_SHADER = 0x8B30,
    GL_VERTEX_SHADER = 0x8B31,
    GL_COMPILE_STATUS = 0x8B81,
    GL_LINK_STATUS = 0x8B82,
    GL_INFO_LOG_LENGTH = 0x8B84,
    GL_FRAMEBUFFER_SRGB = 0x8DB9,
}

extern (System) nothrow @nogc __gshared
{
    void function(GLint, GLint, GLsizei, GLsizei) glViewport;              /// viewport
    void function(GLint, GLint, GLsizei, GLsizei) glScissor;               /// scissor box
    void function(GLenum) glEnable;                                        /// enables a capability
    void function(GLenum) glDisable;                                       /// disables a capability
    void function(GLenum, GLenum) glBlendFunc;                             /// blend factors
    void function(GLfloat, GLfloat, GLfloat, GLfloat) glClearColor;        /// clear color
    void function(GLbitfield) glClear;                                     /// clears buffers
    void function(GLenum) glDepthFunc;                                     /// depth test
    void function(GLsizei, GLuint*) glGenTextures;                         /// texture names
    void function(GLsizei, const(GLuint)*) glDeleteTextures;               /// frees textures
    void function(GLenum, GLuint) glBindTexture;                           /// binds a texture
    void function(GLenum) glActiveTexture;                                 /// texture unit
    void function(GLenum, GLenum, GLint) glTexParameteri;                  /// texture parameter
    void function(GLenum, GLint) glPixelStorei;                            /// pixel store mode
    void function(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const(void)*)
        glTexImage2D;                                                      /// allocates and fills
    void function(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const(void)*)
        glTexSubImage2D;                                                   /// updates a region
    void function(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void*) glReadPixels; /// reads back
    GLuint function(GLenum) glCreateShader;                                /// new shader
    void function(GLuint) glDeleteShader;                                  /// frees a shader
    void function(GLuint, GLsizei, const(GLchar*)*, const(GLint)*) glShaderSource; /// shader text
    void function(GLuint) glCompileShader;                                 /// compiles
    void function(GLuint, GLenum, GLint*) glGetShaderiv;                   /// shader state
    void function(GLuint, GLsizei, GLsizei*, GLchar*) glGetShaderInfoLog;  /// compile log
    GLuint function() glCreateProgram;                                     /// new program
    void function(GLuint) glDeleteProgram;                                 /// frees a program
    void function(GLuint, GLuint) glAttachShader;                          /// attaches a shader
    void function(GLuint) glLinkProgram;                                   /// links
    void function(GLuint, GLenum, GLint*) glGetProgramiv;                  /// program state
    void function(GLuint, GLsizei, GLsizei*, GLchar*) glGetProgramInfoLog; /// link log
    void function(GLuint) glUseProgram;                                    /// binds a program
    GLint function(GLuint, const(GLchar)*) glGetUniformLocation;           /// uniform slot
    void function(GLint, GLint) glUniform1i;                               /// int uniform
    void function(GLint, GLfloat, GLfloat) glUniform2f;                    /// vec2 uniform
    void function(GLint, GLsizei, GLboolean, const(GLfloat)*) glUniformMatrix4fv; /// mat4 uniform
    void function(GLsizei, GLuint*) glGenVertexArrays;                     /// vertex array names
    void function(GLsizei, const(GLuint)*) glDeleteVertexArrays;           /// frees vertex arrays
    void function(GLuint) glBindVertexArray;                               /// binds a vertex array
    void function(GLsizei, GLuint*) glGenBuffers;                          /// buffer names
    void function(GLsizei, const(GLuint)*) glDeleteBuffers;                /// frees buffers
    void function(GLenum, GLuint) glBindBuffer;                            /// binds a buffer
    void function(GLenum, GLsizeiptr, const(void)*, GLenum) glBufferData;  /// fills a buffer
    void function(GLuint, GLint, GLenum, GLboolean, GLsizei, const(void)*) glVertexAttribPointer; /// attribute
    void function(GLuint) glEnableVertexAttribArray;                       /// enables an attribute
    void function(GLenum, GLsizei, GLenum, const(void)*) glDrawElements;   /// indexed draw
    void function(GLenum, GLint, GLsizei) glDrawArrays;                    /// array draw
    const(char)* function(GLenum) glGetString;                             /// driver strings
    GLenum function() glGetError;                                          /// error flag
}

/// Loads every `gl*` pointer above through `getProc`. Returns the name of the first missing one, or null.
string loadGL(void* delegate(const(char)*) getProc)
{
    import std.traits : isFunctionPointer;

    static foreach (string name; __traits(allMembers, dentrite.c.gl))
    {
        static if (name.length > 2 && name[0 .. 2] == "gl" && isFunctionPointer!(mixin(name)))
        {
            mixin(name) = cast(typeof(mixin(name))) getProc((name ~ "\0").ptr);
            if (mixin(name) is null)
            {
                return name;
            }
        }
    }
    return null;
}
