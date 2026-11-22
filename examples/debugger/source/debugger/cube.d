/// Spinning cube drawn with raw GL inside a raw island, to check the seam with 3D views.
module debugger.cube;

import core.time : MonoTime;
import dentrite.backend.gl33 : linkProgram;
import dentrite.c.gl;
import dentrite.geom;
import std.math : cos, sin, tan, PI;

/// Vertex shader: model-view-projection, normal passed through.
private enum string vs = `#version 330 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aNormal;
uniform mat4 uMvp;
uniform mat4 uModel;
out vec3 vNormal;
void main()
{
    vNormal = mat3(uModel) * aNormal;
    gl_Position = uMvp * vec4(aPos, 1.0);
}
`;

/// Fragment shader: one directional light plus ambient.
private enum string fs = `#version 330 core
in vec3 vNormal;
out vec4 outColor;
void main()
{
    vec3 n = normalize(vNormal);
    float d = max(dot(n, normalize(vec3(0.4, 0.8, 0.6))), 0.0);
    vec3 base = vec3(0.23, 0.51, 0.96);
    outColor = vec4(base * (0.25 + 0.75 * d), 1.0);
}
`;

/// Column-major 4x4 matrix.
alias Mat4 = float[16];

/// Product `a * b`.
Mat4 mul(const Mat4 a, const Mat4 b)
{
    Mat4 r = 0;
    foreach (int c; 0 .. 4)
    {
        foreach (int row; 0 .. 4)
        {
            float s = 0;
            foreach (int k; 0 .. 4)
            {
                s += a[k * 4 + row] * b[c * 4 + k];
            }
            r[c * 4 + row] = s;
        }
    }
    return r;
}

/// Perspective projection.
Mat4 perspective(float fovY, float aspect, float near, float far)
{
    float f = 1 / tan(fovY / 2);
    Mat4 m = 0;
    m[0] = f / aspect;
    m[5] = f;
    m[10] = (far + near) / (near - far);
    m[11] = -1;
    m[14] = 2 * far * near / (near - far);
    return m;
}

/// Rotation about Y by `a`, then X by `b`, then a move back by `z`.
Mat4 orbit(float a, float b, float z)
{
    Mat4 ry = [cos(a), 0, -sin(a), 0, 0, 1, 0, 0, sin(a), 0, cos(a), 0, 0, 0, 0, 1];
    Mat4 rx = [1, 0, 0, 0, 0, cos(b), sin(b), 0, 0, -sin(b), cos(b), 0, 0, 0, 0, 1];
    Mat4 t = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, -z, 1];
    return mul(t, mul(rx, ry));
}

/// GL objects and animation clock of the cube.
final class Cube
{
    private GLuint program; /// shader
    private GLuint vao;     /// layout
    private GLuint vbo;     /// 36 vertices with normals
    private GLint uMvp;     /// uniform
    private GLint uModel;   /// uniform
    private MonoTime start; /// animation zero
    bool spinning = true;   /// animate

    /// Creates GL objects lazily on first draw, when the context is current.
    this()
    {
        start = MonoTime.currTime;
    }

    /// Builds the program and the vertex buffer.
    private void setup()
    {
        program = linkProgram(vs, fs);
        uMvp = glGetUniformLocation(program, "uMvp");
        uModel = glGetUniformLocation(program, "uModel");
        float[] v;
        static immutable float[3][6] normals = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]];
        foreach (const float[3] n; normals)
        {
            float[3] u = n[0] != 0 ? [0f, 1, 0] : [1f, 0, 0];
            float[3] w = [n[1] * u[2] - n[2] * u[1], n[2] * u[0] - n[0] * u[2], n[0] * u[1] - n[1] * u[0]];
            float[3][4] corners;
            foreach (int k, float[2] s; [[-1f, -1], [1f, -1], [1f, 1], [-1f, 1]])
            {
                foreach (int d; 0 .. 3)
                {
                    corners[k][d] = 0.5f * (n[d] + s[0] * u[d] + s[1] * w[d]);
                }
            }
            foreach (int idx; [0, 1, 2, 0, 2, 3])
            {
                v ~= corners[idx][];
                v ~= n[];
            }
        }
        glGenVertexArrays(1, &vao);
        glGenBuffers(1, &vbo);
        glBindVertexArray(vao);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, v.length * float.sizeof, v.ptr, GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * float.sizeof, null);
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * float.sizeof, cast(void*)(3 * float.sizeof));
        glBindVertexArray(0);
    }

    /// Custom draw: clears the area and draws the cube in it. Physical pixels, origin top left.
    void draw(Rect area, Rect clip, Size fb)
    {
        if (program == 0)
        {
            setup();
        }
        int x = cast(int) area.x;
        int y = cast(int)(fb.h - area.y - area.h);
        glViewport(x, y, cast(int) area.w, cast(int) area.h);
        glEnable(GL_SCISSOR_TEST);
        Rect s = intersect(area, clip);
        glScissor(cast(int) s.x, cast(int)(fb.h - s.y - s.h), cast(int) s.w, cast(int) s.h);
        glClearColor(0.07f, 0.07f, 0.08f, 1);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        glEnable(GL_DEPTH_TEST);
        glDepthFunc(GL_LESS);
        glDisable(GL_BLEND);
        glEnable(GL_CULL_FACE);
        double t = spinning ? (MonoTime.currTime - start).total!"usecs" / 1e6 : 0.6;
        Mat4 model = orbit(cast(float)(t * 0.9), cast(float)(0.5 + 0.3 * sin(t * 0.7)), 3);
        Mat4 mvp = mul(perspective(PI / 4, area.w / area.h, 0.1f, 100), model);
        glUseProgram(program);
        glUniformMatrix4fv(uMvp, 1, GL_FALSE, mvp.ptr);
        glUniformMatrix4fv(uModel, 1, GL_FALSE, model.ptr);
        glBindVertexArray(vao);
        glDrawArrays(GL_TRIANGLES, 0, 36);
        glBindVertexArray(0);
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_CULL_FACE);
    }
}

/// Identity times a matrix is the matrix, and the projection maps the near plane to -1.
unittest
{
    Mat4 id = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
    Mat4 p = perspective(PI / 2, 1, 1, 10);
    assert(mul(id, p) == p);
    float z = p[10] * -1 + p[14];
    float w = p[11] * -1;
    assert(z / w > -1.0001 && z / w < -0.9999);
}
