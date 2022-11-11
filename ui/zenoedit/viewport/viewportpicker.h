#ifndef VIEWPORT_PICKER_H
#define VIEWPORT_PICKER_H

#include <zeno/utils/vec.h>

#include <QtWidgets>

#include <cfloat>
#include <optional>
#include <unordered_set>

#define CMP(x, y) \
	(fabsf(x - y) <= FLT_EPSILON * fmaxf(1.0f, fmaxf(fabsf(x), fabsf(y))))

using std::string;
namespace zeno {

enum {
    PICK_OBJECT,
    PICK_VERTEX,
    PICK_LINE,
    PICK_FACE
};

static std::optional<float> ray_box_intersect(
    zeno::vec3f const &bmin,
    zeno::vec3f const &bmax,
    zeno::vec3f const &ray_pos,
    zeno::vec3f const &ray_dir
);

static bool test_in_selected_bounding(
    QVector3D centerWS,
    QVector3D cam_posWS,
    QVector3D left_normWS,
    QVector3D right_normWS,
    QVector3D up_normWS,
    QVector3D down_normWS
);

class Picker {
public:
    Picker() : pick_mode(PICK_OBJECT) {};

    void pickWithRay(QVector3D ray_ori, QVector3D ray_dir,
                     const std::function<void(string)>& on_add, const std::function<void(string)>& on_delete);
    void pickWithRay(QVector3D cam_pos, QVector3D left_up, QVector3D left_down, QVector3D right_up, QVector3D right_down,
                     const std::function<void(string)>& on_add, const std::function<void(string)>& on_delete);
    void pickWithFrameBuffer(int x, int y,
                             const std::function<void(string)>& on_add, const std::function<void(string)>& on_delete);
    void pickWithFrameBuffer(int x0, int y0, int x1, int y1,
                             const std::function<void(string)>& on_add, const std::function<void(string)>& on_delete);
    void setPickMode(int mode);
  private:
    int pick_mode;
    inline void onPrimitiveSelected();
};

}

#endif //VIEWPORT_PICKER_H
